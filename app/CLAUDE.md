# Mac app — how to test (#334)

- Test only with `app/tools/test.sh <filter>` (e.g. `app/tools/test.sh MeetingDetectorTests`): your change's tests first. Never `swift test` directly.
- `app/tools/test.sh` with no filter runs the full suite (parallel, about 4 min): once before landing.
- It takes the heavy lock itself and queues behind other heavy work. On failure it prints `--- failing (exit N):` with the failing tests; read that, not raw logs.
- Never erase, shut down, delete or boot a Simulator from the Mac side. That is ios's device, and the gate denies it.
- Test audio only as files through the code's seam. Hotkeys and the microphone are proven in the running app, not by tests alone.
