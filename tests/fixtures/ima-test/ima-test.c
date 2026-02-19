#include <unistd.h>

static const char msg[] = "IMA-TEST-PASS\n";

int main(void) {
	write(1, msg, sizeof(msg) - 1);
	return 0;
}
