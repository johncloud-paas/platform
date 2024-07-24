FROM python:3.11

ARG PORT
ENV PORT=$PORT

WORKDIR /code

COPY tcp_ping/* /code/

RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt

CMD ["fastapi", "run", "/code/main.py", "--proxy-headers", "--port", "${PORT}"]
