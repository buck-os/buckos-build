CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter -fPIC
LDFLAGS ?= -shared -ldl

libkbuild_trace.so: trace.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f libkbuild_trace.so test/sink.jsonl

test: libkbuild_trace.so
	@mkdir -p test
	@rm -f test/sink.jsonl
	@KBUILD_TRACE_FILE=$(PWD)/test/sink.jsonl \
	    LD_PRELOAD=$(PWD)/libkbuild_trace.so \
	    /bin/sh -c '/bin/echo hello; /usr/bin/env true; /bin/false || true' \
	    >/dev/null
	@lines=$$(wc -l < test/sink.jsonl); echo "  captured $$lines exec(s)"
	@python3 -c 'import json,sys; [json.loads(l) for l in open("test/sink.jsonl")]; print("  json:  OK")'
	@grep -q '"path":"/bin/echo"' test/sink.jsonl && echo "  echo:  OK"
	@grep -q '"path":"/usr/bin/env"' test/sink.jsonl && echo "  env:   OK"
	@grep -q '"path":"/bin/false"' test/sink.jsonl && echo "  false: OK"
	@grep -q '"argv":\["true"\]' test/sink.jsonl && echo "  argv:  OK"
	@grep -q '"cwd":"$(PWD)"' test/sink.jsonl && echo "  cwd:   OK"

.PHONY: clean test
