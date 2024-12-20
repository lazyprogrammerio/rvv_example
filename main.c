#include <sys/time.h>
#include <time.h>
#include <stdio.h>
#include <math.h>

struct pt {
  float x;
  float y;
  float z;
};

void vec_len_rvv(float *r, struct pt *v, int n);

void vec_len(float *r, struct pt *v, int n){
  for (int i=0; i<n; ++i){
    struct pt p = v[i];
    r[i] = sqrtf(p.x*p.x + p.y*p.y + p.z*p.z);
  }
}

#define N 100000

int main(){
  float lens[N], lens_rvv[N];
  srand(time(NULL));   // Initialization, should only be called once.
  struct pt v[N];
  time_t t = time(NULL);
  struct tm tm = *localtime(&t);
  printf("now: %d-%02d-%02d %02d:%02d:%02d\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);

  int r0 = 0;
  int r1 = 0;
  int r2 = 0;
  for (int i=0; i<N; ++i){
    v[i].x = rand();
    v[i].y = rand();
    v[i].z = rand();
  }
  struct timeval start, stop;
  double secs = 0;
  gettimeofday(&start, NULL);
  vec_len(lens, v, N);
  gettimeofday(&stop, NULL);
  secs = (double)(stop.tv_usec - start.tv_usec) / 1000000 + (double)(stop.tv_sec - start.tv_sec);
  printf("time taken for C implementation: %f\n",secs);  
  // printf("now: %d-%02d-%02d %02d:%02d:%02d\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
  vec_len_rvv(lens_rvv, v, N);
  gettimeofday(&start, NULL);
  secs = (double)(start.tv_usec - stop.tv_usec) / 1000000 + (double)(start.tv_sec - stop.tv_sec);
  printf("time taken for vector implementation: %f\n",secs);  
  //printf("now: %d-%02d-%02d %02d:%02d:%02d\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
  
  for (int i=0; i<N; ++i){
    //printf("%f %f\n", lens[i], lens_rvv[i]);
  }
  
  tm = *localtime(&t);
  //printf("now: %d-%02d-%02d %02d:%02d:%02d\n", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
  return 0;
}
