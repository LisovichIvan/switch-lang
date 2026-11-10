import os
import select
import sys

process_identifier = int(sys.argv[1])
if process_identifier <= 0:
    raise SystemExit('Expected a positive process identifier')
event_queue = select.kqueue()
try:
    event = select.kevent(process_identifier, filter=select.KQ_FILTER_PROC,
                         flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                         fflags=select.KQ_NOTE_EXIT)
    try:
        events = event_queue.control([event], 1, 10)
        completed = any(received.filter == select.KQ_FILTER_PROC and
                        received.fflags & select.KQ_NOTE_EXIT for received in events)
    except ProcessLookupError:
        completed = True
    if not completed:
        try:
            os.kill(process_identifier, 0)
        except ProcessLookupError:
            completed = True
    if not completed:
        raise SystemExit('Graceful termination not confirmed; no forced termination performed')
finally:
    event_queue.close()
print('Verified previous GUI process exited')
