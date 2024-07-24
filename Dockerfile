FROM python:3.9

WORKDIR /code

COPY tcp_ping/dist/*.whl /code/
COPY tcp_ping/src/tcp_ping/main.py /code/

RUN pip install --no-cache-dir --upgrade -r /code/*.whl

CMD ["fastapi", "run", "/code/main.py", "--proxy-headers", "--port", "80"]
