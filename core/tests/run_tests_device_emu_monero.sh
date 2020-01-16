#!/usr/bin/env bash

: "${RUN_PYTHON_TESTS:=0}"
: "${FORCE_DOCKER_USE:=0}"
: "${RUN_TEST_EMU:=1}"

CORE_DIR="$(SHELL_SESSION_FILE='' && cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )"

upy_pid=""

# run emulator if RUN_TEST_EMU
if [[ $RUN_TEST_EMU > 0 ]]; then
  ../emu.py --disable-animation --temporary-profile --quiet --headless &
  upy_pid=$!
  trezorctl -v wait-for-emulator
fi

DOCKER_ID=""

# Test termination trap
terminate_test() {
  if [[ $# > 0 ]]; then error=$1; fi
  if [ -n "$upy_pid" ]; then kill -- -$upy_pid 2> /dev/null; fi
  if [ -n "$DOCKER_ID" ]; then docker kill $DOCKER_ID 2>/dev/null >/dev/null; fi
  exit $error
}

set -e
trap 'terminate_test $?' EXIT

# run tests
export EC_BACKEND_FORCE=1
export EC_BACKEND=1
export TREZOR_TEST_GET_TX=1
export TREZOR_TEST_LIVE_REFRESH=1
export TREZOR_TEST_SIGN_CL0_HF9=0  # HF9 is no longer active
export TREZOR_TEST_SIGN_CL1_HF9=1
export TREZOR_TEST_SIGN_CL1_HF10=1
error=0

if [[ "$RUN_PYTHON_TESTS" != 0 ]]; then
  python3 -m unittest trezor_monero_test.test_trezor || exit $?
fi

if [[ "$OSTYPE" != "linux-gnu" && "$OSTYPE" != "darwin"* ]]; then
  echo "Tests with native Monero app is supported only on Linux and OSX at the moment. Your OS: $OSTYPE"
  exit 0
fi

error=1
: "${TREZOR_MONERO_TESTS_URL:=https://github.com/ph4r05/monero/releases/download/v0.15.0.0-tests-u18.04-02/trezor_tests}"
: "${TREZOR_MONERO_TESTS_SHA256SUM:=36852ff2add3f865dbf4e23f4e32e1022a8f4b14cd4fb4eb97491d99ba93b9bc}"
: "${TREZOR_MONERO_TESTS_PATH:=$CORE_DIR/tests/trezor_monero_tests}"
: "${TREZOR_MONERO_TESTS_LOG:=$CORE_DIR/tests/trezor_monero_tests.log}"

if [[ ! -f "$TREZOR_MONERO_TESTS_PATH" || "`shasum -a256 "$TREZOR_MONERO_TESTS_PATH" | cut -d' ' -f1`" != $TREZOR_MONERO_TESTS_SHA256SUM ]]; then
  echo "Downloading Trezor monero tests binary ($TREZOR_MONERO_TESTS_SHA256SUM) to `pwd`${TREZOR_MONERO_TESTS_PATH:1}"
  wget -O "$TREZOR_MONERO_TESTS_PATH" "$TREZOR_MONERO_TESTS_URL" \
    && chmod +x "$TREZOR_MONERO_TESTS_PATH" \
    && test "`shasum -a256 "$TREZOR_MONERO_TESTS_PATH" | cut -d' ' -f1`" == "$TREZOR_MONERO_TESTS_SHA256SUM" || exit 1
else
  echo "Trezor monero binary with valid hash ($TREZOR_MONERO_TESTS_SHA256SUM) already present at $TREZOR_MONERO_TESTS_PATH - not downloading again."
fi

echo "Running tests"
TIME_TESTS_START=$SECONDS
if [[ "$OSTYPE" == "linux-gnu" && "$FORCE_DOCKER_USE" != 1 ]]; then
  "$TREZOR_MONERO_TESTS_PATH" 2>&1 > "$TREZOR_MONERO_TESTS_LOG"
  error=$?

elif [[ "$OSTYPE" == "darwin"* || "$FORCE_DOCKER_USE" == 1 ]]; then
  DOCKER_ID=$(docker run -idt --mount type=bind,src="$CORE_DIR",dst="$CORE_DIR" -w "$CORE_DIR" --network=host ubuntu:18.04)
  docker exec $DOCKER_ID apt-get update -qq 2>/dev/null >/dev/null
  docker exec $DOCKER_ID apt-get install --no-install-recommends --no-upgrade -qq net-tools socat 2>/dev/null >/dev/null
  docker exec -d $DOCKER_ID socat UDP-LISTEN:21324,reuseaddr,reuseport,fork UDP4-SENDTO:host.docker.internal:21324
  docker exec -d $DOCKER_ID socat UDP-LISTEN:21325,reuseaddr,reuseport,fork UDP4-SENDTO:host.docker.internal:21325
  docker exec $DOCKER_ID "$TREZOR_MONERO_TESTS_PATH" 2>&1 > "$TREZOR_MONERO_TESTS_LOG"
  error=$?

else
  echo "Unsupported OS: $OSTYPE"
  exit 1
fi


TIME_TESTS_ELAPSED=$((SECONDS-TIME_TESTS_START))

if ((error != 0)); then
  echo "ERROR in trezor tests. Log follows;"
  tail -n 500 "$TREZOR_MONERO_TESTS_LOG"
else
  echo "[PASS] Monero test in $TIME_TESTS_ELAPSED sec. "
  cat "$TREZOR_MONERO_TESTS_LOG" | grep -v DEBUG | egrep '#TEST#|tests.core\b' | tail -n 50
fi

exit $error
