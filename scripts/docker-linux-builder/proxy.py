#!/usr/bin/env python3
"""Local SSH transport with serialized Docker start and idle shutdown."""
import argparse
import asyncio
import contextlib
import json
import logging
import signal
import time


class Proxy:
    def __init__(self, args):
        self.args = args
        self.lock = asyncio.Lock()
        self.active = 0
        self.last_use = time.monotonic()
        self.may_be_running = True  # Inspect once after a proxy restart.

    async def docker(self, *args, check=True):
        proc = await asyncio.create_subprocess_exec(
            self.args.docker, "--context", self.args.context, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        try:
            out, err = await asyncio.wait_for(proc.communicate(), 60)
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                proc.kill()
            await proc.wait()
            raise
        if check and proc.returncode:
            raise RuntimeError(err.decode().strip() or f"docker exited {proc.returncode}")
        return proc.returncode, out

    async def running(self):
        _, raw = await self.docker("inspect", self.args.container)
        info = json.loads(raw)[0]
        if (info["Config"]["Labels"] or {}).get("org.nixos.ssh-activation") != "true":
            raise RuntimeError("refusing to manage a container without the ownership label")
        return info["State"]["Running"]

    async def connect(self):
        async with self.lock:
            if not await self.running():
                logging.info("starting %s", self.args.container)
                await self.docker("start", self.args.container)
            self.may_be_running = True
            deadline = time.monotonic() + 30
            while True:
                try:
                    return await asyncio.open_connection("127.0.0.1", self.args.backend_port)
                except OSError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("container SSH did not become ready within 30 seconds")
                    await asyncio.sleep(0.1)

    @staticmethod
    async def pump(reader, writer):
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()

    async def handle(self, reader, writer):
        self.active += 1  # Reserve before waiting for start/stop's lock.
        backend = None
        pumps = []
        try:
            remote, backend = await self.connect()
            pumps = [asyncio.create_task(self.pump(reader, backend)),
                     asyncio.create_task(self.pump(remote, writer))]
            # A half-close must still allow the server's remaining output through.
            await asyncio.gather(*pumps)
        except (OSError, RuntimeError, TimeoutError) as exc:
            logging.warning("SSH connection ended: %s", exc)
        finally:
            for task in pumps:
                task.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)
            for stream in (backend, writer):
                if stream is not None:
                    stream.close()
                    with contextlib.suppress(OSError):
                        await stream.wait_closed()
            self.active -= 1
            self.last_use = time.monotonic()

    async def stop_if_idle(self):
        async with self.lock:
            if (not self.may_be_running or self.active
                    or time.monotonic() - self.last_use < self.args.idle_seconds):
                return
            if not await self.running():
                self.may_be_running = False
                return
            # Also protects work inherited across a proxy restart or an SSH disconnect.
            code, _ = await self.docker(
                "exec", self.args.container, "pgrep", "-x", "nix-daemon", check=False,
            )
            if code != 1:  # Fail closed on Docker/pgrep errors, too.
                return
            # A connection can arrive during the checks above.
            if self.active:
                return
            logging.info("stopping idle %s", self.args.container)
            await self.docker("stop", "--time", "20", self.args.container)
            self.may_be_running = False

    async def reap(self):
        while True:
            await asyncio.sleep(min(30, self.args.idle_seconds))
            try:
                await self.stop_if_idle()
            except (OSError, RuntimeError, TimeoutError) as exc:
                logging.warning("idle check failed: %s", exc)

    async def serve(self):
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, stop.set)
        server = await asyncio.start_server(self.handle, "127.0.0.1", self.args.port)
        logging.info("listening on 127.0.0.1:%s", self.args.port)
        reaper = asyncio.create_task(self.reap())
        try:
            async with server:
                await stop.wait()
        finally:
            reaper.cancel()
            await asyncio.gather(reaper, return_exceptions=True)
            # Do not stop the container during proxy upgrades/restarts.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--context", default="orbstack")
    parser.add_argument("--container", default="nix-linux-builder")
    parser.add_argument("--port", type=int, default=31023)
    parser.add_argument("--backend-port", type=int, default=31024)
    parser.add_argument("--idle-seconds", type=float, default=300)
    args = parser.parse_args()
    if args.idle_seconds <= 0:
        parser.error("--idle-seconds must be positive")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    asyncio.run(Proxy(args).serve())


if __name__ == "__main__":
    main()
