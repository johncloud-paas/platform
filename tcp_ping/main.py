import os

import asyncio

from tornado.tcpserver import TCPServer
from tornado.iostream import StreamClosedError


class EchoServer(TCPServer):
    async def handle_stream(self, stream, address):
        while True:
            try:
                data = await stream.read_until(b"\n")
                stream.write(data)
            except StreamClosedError:
                break

async def main():
    port=os.environ.get('PORT')
    server = EchoServer()
    server.listen(port)
    await asyncio.Event().wait()

asyncio.run(main())
