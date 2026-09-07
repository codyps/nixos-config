import asyncio
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

from proxy import Proxy


class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    def proxy(self):
        proxy = Proxy(SimpleNamespace(idle_seconds=1, container="test", backend_port=1))
        proxy.last_use = 0
        proxy.running = AsyncMock(return_value=True)
        proxy.docker = AsyncMock(return_value=(1, b""))
        return proxy

    async def test_active_connection_prevents_shutdown(self):
        proxy = self.proxy()
        proxy.active = 1
        await proxy.stop_if_idle()
        proxy.running.assert_not_awaited()

    async def test_daemon_or_failed_check_prevents_shutdown(self):
        for code in (0, 2, 125):
            proxy = self.proxy()
            proxy.docker.return_value = (code, b"")
            await proxy.stop_if_idle()
            self.assertEqual(proxy.docker.await_count, 1)

    async def test_connection_arriving_during_idle_check_prevents_stop(self):
        proxy = self.proxy()

        async def arriving(*args, **kwargs):
            proxy.active += 1
            return 1, b""

        proxy.docker.side_effect = arriving
        await proxy.stop_if_idle()
        self.assertEqual(proxy.docker.await_count, 1)

    async def test_stopped_container_is_not_polled_repeatedly(self):
        proxy = self.proxy()
        await proxy.stop_if_idle()
        proxy.docker.assert_any_await("stop", "--time", "20", "test")
        await proxy.stop_if_idle()
        self.assertEqual(proxy.running.await_count, 1)

    async def test_recent_use_prevents_shutdown(self):
        proxy = self.proxy()
        import time
        proxy.last_use = time.monotonic()
        await proxy.stop_if_idle()
        proxy.running.assert_not_awaited()

    async def test_half_close_preserves_remaining_response(self):
        async def backend(reader, writer):
            data = await reader.read()
            writer.write(data + b" response")
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        remote = await asyncio.start_server(backend, "127.0.0.1", 0)
        proxy = self.proxy()
        port = remote.sockets[0].getsockname()[1]
        proxy.connect = lambda: asyncio.open_connection("127.0.0.1", port)
        front = await asyncio.start_server(proxy.handle, "127.0.0.1", 0)
        async with remote, front:
            reader, writer = await asyncio.open_connection(
                "127.0.0.1", front.sockets[0].getsockname()[1])
            writer.write(b"request")
            writer.write_eof()
            self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"request response")
            writer.close()
            await writer.wait_closed()


if __name__ == "__main__":
    unittest.main()
