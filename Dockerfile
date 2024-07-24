FROM python:3.11

ARG PORT=80
ENV PORT=$PORT

WORKDIR /code

COPY tcp_ping/requirements.txt /code/

RUN pip install --no-cache-dir --upgrade -r /code/requirements.txt

COPY tcp_ping/main.py /code/
COPY tcp_ping/start.sh /code/

CMD ["/bin/sh", "/code/start.sh"]
