# concertpass

Sistema de reservación de boletos para conciertos que soporta picos de demanda
sin vender más boletos que el aforo. Está formado por tres microservicios en
Python (FastAPI) desplegados en un cluster de Amazon EKS.

## Arquitectura

```
 Cliente ──HTTP──▶ ticket-api ──▶ INSERT "pending" ──▶ RDS PostgreSQL
                       │
                       └──▶ mensaje (MessageGroupId = concert_id) ──▶ SQS FIFO
                                                                        │
                  ticket-worker ◀──────────── polling ──────────────────┘
                       │  capacidad del concierto       ◀── DynamoDB
                       │  transacción con FOR UPDATE    ──▶ RDS: booked / rejected
                       │  POST /checkout                ──▶ ticket-checkout (200 OK)
                       ▼
                  RDS: confirmed
```

| Servicio | Responsabilidad |
|---|---|
| `ticket-api` | `POST /reserve` guarda la reserva como `pending` en RDS, la encola en SQS FIFO y regresa su `reservation_id`. `GET /reservation/{id}` regresa su estado. |
| `ticket-worker` | Consume la cola. Lee la capacidad del concierto en DynamoDB, suma los boletos vendidos en RDS dentro de una transacción con `FOR UPDATE` y marca la reserva como `booked` o `rejected`. Si queda `booked`, llama a `ticket-checkout` y la marca como `confirmed`. |
| `ticket-checkout` | Simula un procesador de pagos: `POST /checkout` siempre responde 200. |

Estados de una reserva: `pending` → `booked` → `confirmed`, o `pending` →
`rejected` si no hay lugar.

### Cómo se evita la sobreventa

1. **SQS FIFO con `MessageGroupId = concert_id`**: las reservas de un mismo
   concierto se entregan en orden.
2. **Transacción en PostgreSQL**: `ticket-worker` toma un
   `pg_advisory_xact_lock` por concierto y tipo de boleto, suma los boletos
   `booked`/`confirmed` con `SELECT ... FOR UPDATE` y solo marca `booked` si
   `vendidos + cantidad <= capacidad`. El advisory lock cubre el caso en que aún
   no hay filas vendidas que `FOR UPDATE` pueda bloquear.
3. Si no hay lugar, la transacción hace `ROLLBACK` y el `rejected` se escribe en
   una transacción separada que solo modifica esa fila.

## Estructura

```
apps/
  ticket-api/        API de reservas (Dockerfile, main.py, requirements.txt)
  ticket-worker/     Worker que consume SQS
  ticket-checkout/   Simulador de pagos
k8s/                 Namespace, Deployments y Services
scripts/             Creación de la infraestructura, despliegue, pruebas y teardown
```

## Configuración

Los servicios leen toda su configuración de variables de entorno:

| Variable | Origen en EKS | Usada por |
|---|---|---|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Secret `concertpass-db`, creado a partir de Secrets Manager (`concertpass/db`) | api, worker |
| `QUEUE_URL`, `AWS_DEFAULT_REGION` | ConfigMap `concertpass-config` | api, worker |
| `CHECKOUT_URL` | ConfigMap `concertpass-config` | worker |

Los pods usan el rol IAM de los nodos (`LabRole` en AWS Academy) para hablar
con SQS y DynamoDB. Los valores por defecto de los scripts (región, nombres de
recursos) están en `scripts/config.sh`.

## Requisitos

Git Bash o una terminal Unix, AWS CLI v2, Docker, `eksctl`, `kubectl` (1.33 o
más reciente) y Python 3, con credenciales de AWS exportadas en la terminal.

## Despliegue

Desde la raíz del repositorio, en este orden:

```bash
export DB_PASSWORD='<contraseña de RDS>'

bash scripts/create-sqs.sh          # cola concertpass-reservations.fifo
bash scripts/create-rds.sh          # Postgres concertpass-db (5-10 min)
bash scripts/create-dynamodb.sh     # tabla events con 2 conciertos
bash scripts/create-db-secret.sh    # credenciales de RDS en Secrets Manager
bash scripts/publish-image.sh       # imágenes de los 3 servicios en ECR
bash scripts/create-eks.sh          # cluster EKS con 2 nodos (15-20 min)
bash scripts/deploy-k8s.sh          # despliega los servicios e imprime API_URL

kubectl get nodes                   # 2 nodos Ready
kubectl -n concertpass get pods,svc
export API_URL="http://<hostname que imprimió deploy-k8s.sh>"
```

## Uso

```bash
curl -s -X POST "$API_URL/reserve" \
  -H "Content-Type: application/json" \
  -d '{"concert_id":"concert-nicho","user_id":"usr_123","ticket_type":"vip","quantity":2}'

curl -s "$API_URL/reservation/<reservation_id>"
```

Conciertos precargados en DynamoDB:

| `concert_id` | Fecha | Recinto | general | vip |
|---|---|---|---|---|
| `concert-nicho` | 2026-11-20 | Foro Independencia, GDL | 500 | 50 |
| `concert-alta-demanda` | 2026-12-05 | Estadio Akron, GDL | 100 | 10 |

## Pruebas de carga

`scripts/load-test.py` envía reservas concurrentes y verifica que no haya
sobreventa. Antes de cada escenario se limpian las reservas del concierto:

```bash
bash scripts/reset-reservations.sh concert-nicho
python scripts/load-test.py --scenario nicho            # 20 reservas: todas confirmed

bash scripts/reset-reservations.sh concert-alta-demanda
python scripts/load-test.py --scenario alta-demanda     # 300 reservas: 100 confirmed, 200 rejected

bash scripts/reservations-summary.sh    # conteo por estado y boletos vendidos en RDS
bash scripts/query-reservations.sh      # todas las filas de reservations
```

Para probar varios workers en paralelo:

```bash
kubectl -n concertpass scale deployment ticket-worker --replicas=3
```

## Eliminar los recursos

```bash
bash scripts/teardown.sh
```

Borra el namespace de Kubernetes (y su LoadBalancer), los repositorios de ECR,
RDS y su security group, el cluster EKS, la tabla de DynamoDB, el secreto y la
cola SQS.
