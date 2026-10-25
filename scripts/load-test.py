"""Dispara reservas concurrentes contra ticket-api y verifica que no haya sobreventa.

Uso:
    python scripts/load-test.py --url http://<api> --scenario alta-demanda
    python scripts/load-test.py --scenario nicho          # usa $API_URL

Escenarios (capacidades precargadas por scripts/create-dynamodb.sh):
    nicho         pocas solicitudes sobre un concierto con capacidad holgada;
                  se espera que todas queden confirmadas.
    alta-demanda  muchas solicitudes simultáneas que superan la capacidad;
                  se espera que el sistema rechace el excedente.

Solo usa la biblioteca estándar. El resultado considera únicamente las reservas
de esta ejecución: para que la verificación sea exacta, limpia antes las
reservas del concierto con scripts/reset-reservations.sh.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

SCENARIOS = {
    "nicho": {
        "concert_id": "concert-nicho",
        "capacity": {"general": 500, "vip": 50},
        "requests": 20,
        "concurrency": 5,
    },
    "alta-demanda": {
        "concert_id": "concert-alta-demanda",
        "capacity": {"general": 100, "vip": 10},
        "requests": 300,
        "concurrency": 50,
    },
}
FINAL_STATUSES = {"confirmed", "rejected"}
SOLD_STATUSES = {"booked", "confirmed"}


def http_json(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url, data=data, method=method, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)


def reserve(api_url, concert_id, ticket_type, quantity):
    body = {
        "concert_id": concert_id,
        "user_id": f"loadtest-{uuid.uuid4().hex[:8]}",
        "ticket_type": ticket_type,
        "quantity": quantity,
    }
    try:
        return http_json("POST", f"{api_url}/reserve", body)["reservation_id"]
    except (urllib.error.URLError, TimeoutError) as error:
        print(f"  POST /reserve falló: {error}", file=sys.stderr)
        return None


def fetch_status(api_url, reservation_id):
    try:
        return http_json("GET", f"{api_url}/reservation/{reservation_id}")["status"]
    except (urllib.error.URLError, TimeoutError):
        return "pending"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", default=os.environ.get("API_URL"),
                        help="URL base de ticket-api (por defecto $API_URL)")
    parser.add_argument("--scenario", choices=SCENARIOS, default="alta-demanda")
    parser.add_argument("--requests", type=int, help="total de reservas a enviar")
    parser.add_argument("--concurrency", type=int, help="solicitudes simultáneas")
    parser.add_argument("--ticket-type", default="general")
    parser.add_argument("--quantity", type=int, default=1)
    parser.add_argument("--wait", type=int, default=300,
                        help="segundos máximos esperando a que el worker procese todo")
    args = parser.parse_args()
    if not args.url:
        parser.error("indica --url o define API_URL")

    scenario = SCENARIOS[args.scenario]
    api_url = args.url.rstrip("/")
    concert_id = scenario["concert_id"]
    capacity = scenario["capacity"][args.ticket_type]
    total = args.requests or scenario["requests"]
    concurrency = args.concurrency or scenario["concurrency"]

    print(f"Escenario {args.scenario}: {total} reservas de {args.quantity} boleto(s) "
          f"{args.ticket_type} para {concert_id} (capacidad {capacity}), "
          f"{concurrency} en paralelo")

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        started = time.monotonic()
        ids = list(pool.map(
            lambda _: reserve(api_url, concert_id, args.ticket_type, args.quantity),
            range(total),
        ))
        print(f"Enviadas en {time.monotonic() - started:.1f}s; "
              f"{ids.count(None)} solicitudes fallaron")

        statuses = {reservation_id: "pending" for reservation_id in ids if reservation_id}
        if not statuses:
            sys.exit("No se creó ninguna reserva; revisa la URL de ticket-api")
        deadline = time.monotonic() + args.wait
        while time.monotonic() < deadline:
            unresolved = [rid for rid, status in statuses.items()
                          if status not in FINAL_STATUSES]
            if not unresolved:
                break
            for rid, status in zip(unresolved, pool.map(
                    lambda rid: fetch_status(api_url, rid), unresolved)):
                statuses[rid] = status
            counts = Counter(statuses.values())
            print(f"  progreso: {dict(sorted(counts.items()))}")
            time.sleep(2)

    counts = Counter(statuses.values())
    sold = sum(counts[status] for status in SOLD_STATUSES) * args.quantity
    print("\nResultado por estado:")
    for status, count in sorted(counts.items()):
        print(f"  {status:<10} {count}")
    print(f"Boletos vendidos: {sold} / capacidad {capacity}")

    if sold > capacity:
        print("SOBREVENTA DETECTADA")
        sys.exit(1)
    if counts["pending"]:
        print(f"Aún hay {counts['pending']} reservas pendientes; aumenta --wait")
        sys.exit(2)
    print("OK: no hubo sobreventa")


if __name__ == "__main__":
    main()
