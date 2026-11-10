"""Test the real CMD launchers with a disposable fake engine, without switching."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    source = Path(__file__).resolve().parent.parent
    compiler = Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework/v4.0.30319/csc.exe"
    with tempfile.TemporaryDirectory(prefix="codex-launcher-test-中文 空格-") as directory:
        root = Path(directory)
        for name in ("codex-switcher.cmd", "switch-api.cmd", "switch-official.cmd"):
            shutil.copyfile(source / name, root / name)
        stub = root / "Engine.cs"
        stub.write_text(
            'using System; class Engine { static int Main(string[] args) {'
            'Console.WriteLine("ENGINE_READY:" + string.Join("|", args));'
            'return int.Parse(Environment.GetEnvironmentVariable("TEST_ENGINE_EXIT")); }}',
            encoding="utf-8",
        )
        binary = root / "engine.exe"
        subprocess.run([str(compiler), "/nologo", "/target:exe", f"/out:{binary}", str(stub)],
                       check=True, capture_output=True)
        count = 0
        for engine in ("pwsh.exe", "powershell.exe"):
            engine_path = root / engine
            shutil.copyfile(binary, engine_path)
            for launcher, args in (("codex-switcher.cmd", ""), ("codex-switcher.cmd", "status"),
                                   ("switch-api.cmd", ""), ("switch-official.cmd", "")):
                for result in (0, 7):
                    env = os.environ.copy()
                    env.pop("CODEX_SWITCHER_NO_PAUSE", None)
                    env["PATH"] = str(root) + os.pathsep + str(Path(env["WINDIR"]) / "System32")
                    env["TEST_ENGINE_EXIT"] = str(result)
                    command = f'"{env["COMSPEC"]}" /d /s /c ""{root / launcher}" {args}"'
                    proc = subprocess.Popen(command,
                                            cwd=root, env=env, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    try:
                        first = proc.stdout.readline()
                        assert b"ENGINE_READY:" in first, first
                        if launcher != "codex-switcher.cmd":
                            expected = b"api" if launcher == "switch-api.cmd" else b"official"
                            assert first.rstrip().endswith(b"|" + expected), first
                        time.sleep(0.15)
                        assert proc.poll() is None, f"{launcher} exited before a key was pressed"
                        output = first + proc.communicate(b"x", timeout=5)[0]
                        assert proc.returncode == result, (launcher, proc.returncode, output)
                        assert "按任意键退出".encode("utf-8") in output, output
                        assert output.count(b". . .") == 1, f"Expected exactly one pause: {output!r}"
                    finally:
                        if proc.poll() is None:
                            proc.kill()
                            proc.communicate()
                    count += 1
            env["CODEX_SWITCHER_NO_PAUSE"] = "1"
            env["TEST_ENGINE_EXIT"] = "7"
            skipped = subprocess.run(f'"{env["COMSPEC"]}" /d /s /c ""{root / "codex-switcher.cmd"}" status"',
                                     cwd=root, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
            assert skipped.returncode == 7 and b". . ." not in skipped.stdout, skipped.stdout
            engine_path.unlink()
            count += 1
        print(f"CMD launcher tests passed: {count} cases; key wait, single pause, exit codes, arguments, both engines, no-pause automation.")


if __name__ == "__main__":
    main()
