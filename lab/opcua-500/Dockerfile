# SPDX-License-Identifier: AGPL-3.0-only
# Lab-only OPC UA simulator (500 nodes). Not part of a default install.

FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY server.py .

EXPOSE 4840

CMD ["python", "-u", "server.py"]
