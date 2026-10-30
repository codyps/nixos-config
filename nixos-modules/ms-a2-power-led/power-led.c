#define _DEFAULT_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/io.h>
#include <time.h>
#include <unistd.h>

/* MS-A2 FRG BIOS 1.03, OemECHwMonitor: Setup[0x72] -> EC command DF.
 * Only the secondary EC interface (68/6c) is touched; no NVRAM writes.
 */
static int ready(void) {
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    if (!(inb(0x6c) & 2))
      return 0;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if ((now.tv_sec - start.tv_sec) * 1000000000LL + now.tv_nsec -
            start.tv_nsec >
        300000000LL) {
      fputs("EC input buffer remained busy; aborted.\n", stderr);
      return -1;
    }
    usleep(1000);
  }
}
int main(int argc, char **argv) {
  unsigned long value = 0;
  if (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) {
    puts("Usage: sudo sys power-led-brightness VALUE|--probe\nVALUE is 0..255. "
         "Changes live brightness only; does not save a BIOS default.\n--probe "
         "reads EC status, not the current brightness.");
    return 0;
  }
  if (argc != 2) {
    fputs("Usage: sudo sys power-led-brightness VALUE(0..255)|--probe\n",
          stderr);
    return 2;
  }
  int probe = !strcmp(argv[1], "--probe");
  if (!probe) {
    char *end;
    errno = 0;
    value = strtoul(argv[1], &end, 10);
    if (errno || !*argv[1] || *end || !isdigit((unsigned char)argv[1][0]) ||
        value > 255) {
      fputs("Brightness must be an integer from 0 to 255.\n", stderr);
      return 2;
    }
  }
  char model[80] = {0};
  FILE *f = fopen("/sys/class/dmi/id/product_name", "r");
  if (!f || !fgets(model, sizeof model, f)) {
    fputs("Cannot identify system.\n", stderr);
    return 1;
  }
  fclose(f);
  if (strcmp(model, "MS-A2\n")) {
    fputs("This helper only supports MS-A2.\n", stderr);
    return 1;
  }
  int lock = open("/run/lock/ms-a2-power-led.lock",
                  O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB)) {
    perror("Cannot lock power LED controller");
    return 1;
  }
  if (ioperm(0x68, 1, 1) || ioperm(0x6c, 1, 1)) {
    perror("ioperm (requires root/CAP_SYS_RAWIO)");
    return 1;
  }
  unsigned char status = inb(0x6c);
  if (status == 0xff) {
    fputs("EC port returned FF; aborted.\n", stderr);
    return 1;
  }
  if (probe) {
    printf(
        "Secondary EC status: 0x%02x (IBF=%u, OBF=%u). No writes performed.\n",
        status, !!(status & 2), !!(status & 1));
    return 0;
  }
  if (ready())
    return 1;
  outb(0xdf, 0x6c);
  if (ready())
    return 1;
  outb((unsigned char)value, 0x68);
  if (ready())
    return 1;
  printf("Set power LED PWM to %lu (runtime only).\n", value);
  return 0;
}
