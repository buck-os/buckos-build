#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static const char msg[] = "IMA-TEST-PASS\n";

int main(void) {
	write(1, msg, sizeof(msg) - 1);

	int fd = open("/mnt/test-data.txt", O_RDONLY);
	if (fd < 0) {
		if (errno == EACCES) {
			const char *denied = "IMA-FILE-DENIED\n";
			write(1, denied, strlen(denied));
			return 1;
		}
		const char *err = "IMA-FILE-ERROR: ";
		write(1, err, strlen(err));
		const char *s = strerror(errno);
		write(1, s, strlen(s));
		write(1, "\n", 1);
		return 1;
	}

	char buf[256];
	ssize_t n;
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		write(1, buf, n);
	close(fd);
	return 0;
}
