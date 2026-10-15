#!/usr/bin/env bash
set -euo pipefail

aws sqs create-queue \
  --queue-name concertpass-reservations.fifo \
  --attributes FifoQueue=true,ContentBasedDeduplication=true \
  --region us-east-1
  