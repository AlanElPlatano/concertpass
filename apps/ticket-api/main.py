import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import psycopg
from fastapi import FastAPI
from pydantic import BaseModel, Field

CONFIRMED_STATUS = "confirmed"

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


@app.post("/reserve")
def reserve(request: ReservationRequest):
    reservation_id = uuid.uuid4()
    now = datetime.now(timezone.utc)
    with connect() as connection:
        connection.execute(INSERT_RESERVATION, (
            reservation_id, request.concert_id, request.user_id,
            request.ticket_type, request.quantity, CONFIRMED_STATUS, now, now,
        ))
    return {"reservation_id": str(reservation_id), "status": CONFIRMED_STATUS}
