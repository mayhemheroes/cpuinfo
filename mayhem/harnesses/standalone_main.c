/* Standalone run-once driver for the cpuinfo libFuzzer harness.
 *
 * Reads ONE input file (argv[1]), feeds its bytes to LLVMFuzzerTestOneInput,
 * and exits. No libFuzzer runtime — used to build the *-standalone reproducer
 * so a crashing input can be replayed under a debugger / verified outside Mayhem.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE* fp = fopen(argv[1], "rb");
  if (fp == NULL) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  fseek(fp, 0, SEEK_SET);
  if (size < 0) {
    fclose(fp);
    return 3;
  }
  uint8_t* data = (uint8_t*)malloc((size_t)size ? (size_t)size : 1);
  if (data == NULL) {
    fclose(fp);
    return 3;
  }
  size_t n = (size > 0) ? fread(data, (size_t)size, 1, fp) : 0;
  fclose(fp);
  if (size > 0 && n != 1) {
    fprintf(stderr, "read failed\n");
    free(data);
    return 4;
  }
  LLVMFuzzerTestOneInput(data, (size_t)size);
  free(data);
  return 0;
}
