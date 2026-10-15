import os
import time
import boto3

sqs = boto3.client("sqs", region_name="us-east-1")
QUEUE_URL = os.environ.get("QUEUE_URL")

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
                print("Mensaje recibido:", msg["Body"])
                sqs.delete_message(
                    QueueUrl=QUEUE_URL,
                    ReceiptHandle=msg["ReceiptHandle"],
                )
                print("Mensaje eliminado de la cola.")
        else:
            print("Sin mensajes nuevos.")

        time.sleep(5)

if __name__ == "__main__":
    main()