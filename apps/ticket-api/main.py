import os
import uuid
import json # NUEVO: Para convertir el mensaje a formato JSON
import boto3 # NUEVO: SDK de AWS para Python
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import psycopg
from fastapi import FastAPI, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel, Field

# MODIFICADO: El estado inicial ahora es pending
PENDING_STATUS = "pending"

CREATE_RESERVATIONS_TABLE = """
CREATE TABLE IF NOT EXISTS reservations (
  reservation_id  UUID PRIMARY KEY,
  concert_id      VARCHAR   NOT NULL,
  user_id         VARCHAR   NOT NULL,
  ticket_type     VARCHAR   NOT NULL,
  quantity        INTEGER   NOT NULL,
  status          VARCHAR   NOT NULL,
  created_at      TIMESTAMP NOT NULL,
  updated_at      TIMESTAMP NOT NULL
);
"""

INSERT_RESERVATION = """
INSERT INTO reservations (reservation_id, concert_id, user_id, ticket_type,
                          quantity, status, created_at, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
"""

SELECT_RESERVATION = """
SELECT reservation_id, concert_id, user_id, ticket_type, quantity, status,
       created_at, updated_at
FROM reservations
WHERE reservation_id = %s;
"""


class ReservationRequest(BaseModel):
    concert_id: str
    user_id: str
    ticket_type: str
    quantity: int = Field(gt=0)


def connect():
    return psycopg.connect(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )


@asynccontextmanager
async def lifespan(_: FastAPI):
    with connect() as connection:
        connection.execute(CREATE_RESERVATIONS_TABLE)
    yield


app = FastAPI(title="ticket-api", lifespan=lifespan)

# NUEVO: Inicializar cliente de SQS
sqs_client = boto3.client("sqs")
# NUEVO: Leer la URL de la cola desde variables de entorno
QUEUE_URL = os.environ.get("QUEUE_URL")


@app.post("/reserve")
def reserve(request: ReservationRequest):
    reservation_id = uuid.uuid4()
    now = datetime.now(timezone.utc)
    
    # 1. MODIFICADO: Insertar en la base de datos como PENDING
    with connect() as connection:
        connection.execute(INSERT_RESERVATION, (
            reservation_id, request.concert_id, request.user_id,
            request.ticket_type, request.quantity, PENDING_STATUS, now, now,
        ))
    
    # 2. NUEVO: Preparar el payload del mensaje
    message_body = {
        "reservation_id": str(reservation_id),
        "concert_id": request.concert_id,
        "user_id": request.user_id,
        "ticket_type": request.ticket_type,
        "quantity": request.quantity
    }
    
    # 3. NUEVO: Enviar a la cola SQS FIFO
    sqs_client.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(message_body),
        MessageGroupId=request.concert_id, # Requerido para colas FIFO
        MessageDeduplicationId=str(reservation_id) # Requerido para colas FIFO, previene duplicados
    )

    # MODIFICADO: Retornar estado PENDING
    return {"reservation_id": str(reservation_id), "status": PENDING_STATUS}


@app.get("/reservation/{reservation_id}")
def get_reservation(reservation_id: uuid.UUID):
    with connect() as connection, connection.cursor(row_factory=dict_row) as cursor:
        reservation = cursor.execute(SELECT_RESERVATION, (reservation_id,)).fetchone()
    if reservation is None:
        raise HTTPException(status_code=404, detail="Reservation not found")
    return reservation
