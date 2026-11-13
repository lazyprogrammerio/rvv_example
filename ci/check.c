// Compares vec_len_rvv against a scalar reference; exits non-zero on mismatch.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

struct pt {
  float x;
  float y;
  float z;
};

void vec_len_rvv(float *r, struct pt *v, int n);

#define N 100003 /* not a multiple of any VL, so the tail is exercised */
#define GUARD 16
#define SENTINEL -1.0f

static struct pt v[N];
static float out[N + GUARD];

static float coord(void) { return rand() / (float)RAND_MAX * 200.0f - 100.0f; }

int main(void) {
  srand(1);
  for (int i = 0; i < N; ++i) {
    v[i].x = coord();
    v[i].y = coord();
    v[i].z = coord();
  }
  for (int i = 0; i < N + GUARD; ++i)
    out[i] = SENTINEL;

  vec_len_rvv(out, v, N);

  int bad = 0;
  double maxrel = 0;
  for (int i = 0; i < N; ++i) {
    float ref = sqrtf(v[i].x * v[i].x + v[i].y * v[i].y + v[i].z * v[i].z);
    double rel = fabs((double)ref - out[i]) / ref;
    if (rel > maxrel)
      maxrel = rel;
    if (!(rel <= 1e-6))
      bad++;
  }
  for (int i = N; i < N + GUARD; ++i)
    if (out[i] != SENTINEL)
      bad++;

  printf("n=%d mismatches=%d max_rel_err=%g\n", N, bad, maxrel);
  return bad != 0;
}
