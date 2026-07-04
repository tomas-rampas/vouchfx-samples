# app/Dockerfile — inventory-python sample service image.
#
# Built as the vouchfx system under test (environment.services.inventory-api
# in tests/inventory.e2e.yaml). Non-root, single small layer of dependencies
# separated from the (much more frequently changing) application code.

FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py ./

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
USER appuser

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
