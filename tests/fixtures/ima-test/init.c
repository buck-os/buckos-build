#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define CMDLINE_BUF 512

static const char *parse_ima_test_mode(void)
{
	static char buf[CMDLINE_BUF];
	int fd = open("/proc/cmdline", O_RDONLY);
	if (fd < 0)
		return NULL;
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return NULL;
	buf[n] = '\0';

	const char *key = "ima_test_mode=";
	char *p = strstr(buf, key);
	if (!p)
		return NULL;
	p += strlen(key);

	/* null-terminate at next space or newline */
	char *end = p;
	while (*end && *end != ' ' && *end != '\n')
		end++;
	*end = '\0';
	return p;
}

static void write_ima_policy(void)
{
	int fd = open("/sys/kernel/security/ima/policy", O_WRONLY);
	if (fd < 0) {
		printf("INIT: cannot open IMA policy: %s\n", strerror(errno));
		return;
	}
	const char *rule = "appraise func=BPRM_CHECK fowner=0\n";
	if (write(fd, rule, strlen(rule)) < 0)
		printf("INIT: write IMA policy failed: %s\n", strerror(errno));
	else
		printf("INIT: IMA appraise policy loaded\n");
	close(fd);
}

static void write_ima_policy_file_check(void)
{
	int fd = open("/sys/kernel/security/ima/policy", O_WRONLY);
	if (fd < 0) {
		printf("INIT: cannot open IMA policy: %s\n", strerror(errno));
		return;
	}
	const char *r1 = "appraise func=BPRM_CHECK fowner=0\n";
	const char *r2 = "appraise func=FILE_CHECK fowner=0\n";
	if (write(fd, r1, strlen(r1)) < 0)
		printf("INIT: write BPRM_CHECK policy failed: %s\n",
		       strerror(errno));
	if (write(fd, r2, strlen(r2)) < 0)
		printf("INIT: write FILE_CHECK policy failed: %s\n",
		       strerror(errno));
	else
		printf("INIT: IMA appraise policy loaded (BPRM_CHECK + FILE_CHECK)\n");
	close(fd);
}

int main(void)
{
	/* Mount essential filesystems */
	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	mount("securityfs", "/sys/kernel/security", "securityfs", 0, NULL);

	printf("INIT: started\n");

	const char *mode = parse_ima_test_mode();
	if (!mode) {
		printf("INIT: no ima_test_mode= on cmdline\n");
		printf("IMA-RESULT:FAIL\n");
		reboot(RB_POWER_OFF);
		return 1;
	}
	printf("INIT: ima_test_mode=%s\n", mode);

	int expect_eacces = 0;
	int expect_file_denied = 0;
	if (strcmp(mode, "enforce_signed") == 0) {
		write_ima_policy();
	} else if (strcmp(mode, "enforce_unsigned") == 0) {
		write_ima_policy();
		expect_eacces = 1;
	} else if (strcmp(mode, "file_signed") == 0) {
		write_ima_policy_file_check();
	} else if (strcmp(mode, "file_unsigned") == 0) {
		write_ima_policy_file_check();
		expect_file_denied = 1;
	} else if (strcmp(mode, "noima") == 0) {
		/* no policy — IMA appraisal inactive */
	} else {
		printf("INIT: unknown mode '%s'\n", mode);
		printf("IMA-RESULT:FAIL\n");
		reboot(RB_POWER_OFF);
		return 1;
	}

	/* Mount the test disk */
	mkdir("/mnt", 0755);
	if (mount("/dev/vda", "/mnt", "ext4", MS_RDONLY, NULL) != 0) {
		printf("INIT: mount /dev/vda failed: %s\n", strerror(errno));
		printf("IMA-RESULT:FAIL\n");
		reboot(RB_POWER_OFF);
		return 1;
	}
	printf("INIT: mounted /dev/vda at /mnt\n");

	/* Fork and exec the test binary */
	pid_t pid = fork();
	if (pid < 0) {
		printf("INIT: fork failed: %s\n", strerror(errno));
		printf("IMA-RESULT:FAIL\n");
		reboot(RB_POWER_OFF);
		return 1;
	}

	if (pid == 0) {
		/* child */
		execl("/mnt/ima-test", "/mnt/ima-test", NULL);
		/* exec failed — print errno for parent to diagnose */
		printf("INIT: exec failed: %s (errno=%d)\n", strerror(errno), errno);
		_exit(errno);
	}

	/* parent — wait for child */
	int status = 0;
	waitpid(pid, &status, 0);

	if (expect_eacces) {
		/*
		 * We expect exec to fail with EACCES (13).
		 * The child calls _exit(errno) on exec failure.
		 */
		if (WIFEXITED(status) && WEXITSTATUS(status) == EACCES) {
			printf("INIT: exec rejected with EACCES as expected\n");
			printf("IMA-RESULT:PASS\n");
		} else {
			printf("INIT: expected EACCES, got exit=%d\n",
			       WIFEXITED(status) ? WEXITSTATUS(status) : -1);
			printf("IMA-RESULT:FAIL\n");
		}
	} else if (expect_file_denied) {
		/*
		 * Binary is signed so exec succeeds, but the data file
		 * is unsigned so the file read should fail (non-zero exit).
		 */
		if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
			printf("INIT: file access denied as expected (exit=%d)\n",
			       WEXITSTATUS(status));
			printf("IMA-RESULT:PASS\n");
		} else {
			printf("INIT: expected file denial, got exit=%d\n",
			       WIFEXITED(status) ? WEXITSTATUS(status) : -1);
			printf("IMA-RESULT:FAIL\n");
		}
	} else {
		/* We expect the binary to run and print IMA-TEST-PASS */
		if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
			printf("INIT: child exited 0\n");
			printf("IMA-RESULT:PASS\n");
		} else {
			printf("INIT: child failed, exit=%d\n",
			       WIFEXITED(status) ? WEXITSTATUS(status) : -1);
			printf("IMA-RESULT:FAIL\n");
		}
	}

	sync();
	reboot(RB_POWER_OFF);
	return 0;
}
