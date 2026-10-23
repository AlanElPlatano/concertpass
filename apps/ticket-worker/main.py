import os
import time
import json
import boto3
import psycopg
import requests

sqs = boto3.client("sqs", region_name="us-east-1")
dynamodb = boto3.client("dynamodb", region_name="us-east-1")

QUEUE_URL = os.environ.get("QUEUE_URL")
# Agregamos la URL del checkout; por defecto apuntará al puerto 8081 local
CHECKOUT_URL = os.environ.get("CHECKOUT_URL", "http://localhost:8081/checkout")

def connect():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )

def process_message(msg):
    body = json.loads(msg["Body"])
    reservation_id = body["reservation_id"]
    concert_id = body["concert_id"]
    ticket_type = body["ticket_type"]
    quantity = int(body["quantity"])

    # 1. Consultar capacidad máxima en DynamoDB
    response = dynamodb.get_item(
        TableName="events",
        Key={"concert_id": {"S": concert_id}}
    )
    
    item = response.get("Item")
    if not item:
        print(f"Error: Concierto {concert_id} no encontrado en Dynamo.")
        return

    # Extraer la capacidad específica para el tipo de boleto (ej. "vip")
    capacity_str = item["capacity"]["M"].get(ticket_type, {}).get("N", "0")
    max_capacity = int(capacity_str)

    # 2. Transacción en PostgreSQL con FOR UPDATE
    with connect() as conn:
        with conn.cursor() as cur:
            # Bloquea las filas calculadas para evitar race conditions
            cur.execute("""
                SELECT COALESCE(SUM(quantity), 0) 
                FROM (
                    SELECT quantity 
                    FROM reservations 
                    WHERE concert_id = %s 
                    AND ticket_type = %s 
                    AND status IN ('booked', 'confirmed') 
                    FOR UPDATE
                ) AS locked_rows;
            """, (concert_id, ticket_type))
            
            sold_tickets = cur.fetchone()[0]

            if sold_tickets + quantity <= max_capacity:
                cur.execute("""
                    UPDATE reservations 
                    SET status = 'booked', updated_at = NOW() 
                    WHERE reservation_id = %s;
                """, (reservation_id,))
                conn.commit()
                print(f"Reserva {reservation_id} BOOKED. Iniciando checkout...")
                
                # 3. Llamar a ticket-checkout
                checkout_payload = {
                    "reservation_id": reservation_id,
                    "quantity": quantity
                }
                try:
                    resp = requests.post(CHECKOUT_URL, json=checkout_payload)
                    if resp.status_code == 200:
                        cur.execute("""
                            UPDATE reservations 
                            SET status = 'confirmed', updated_at = NOW() 
                            WHERE reservation_id = %s;
                        """, (reservation_id,))
                        conn.commit()
                        print(f"Reserva {reservation_id} CONFIRMED.")
                except Exception as e:
                    print(f"Error al conectar con checkout: {e}")
            else:
                conn.rollback() # Libera el bloqueo del FOR UPDATE
                
                # Actualiza a rejected en una transacción separada
                with connect() as conn2:
                    with conn2.cursor() as cur2:
                        cur2.execute("""
                            UPDATE reservations 
                            SET status = 'rejected', updated_at = NOW() 
                            WHERE reservation_id = %s;
                        """, (reservation_id,))
                        conn2.commit()
                print(f"Reserva {reservation_id} REJECTED. Sin capacidad.")

def main():
    if not QUEUE_URL:
        raise ValueError("QUEUE_URL no está definida")

    print(f"ticket-worker iniciado. Escuchando: {QUEUE_URL}")

    while True:
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=5,
        )

        messages = response.get("Messages", [])
        if messages:
            for msg in messages:
                print("Procesando mensaje SQS...")
                process_message(msg)
                
                # El mensaje se elimina solo si se procesó sin crashear
                sqs.delete_message(
                    QueueUrl=QUEUE_URL,
                    ReceiptHandle=msg["ReceiptHandle"],
                )
        time.sleep(1)

if __name__ == "__main__":
    main()