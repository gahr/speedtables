#include <stdio.h>
#include <time.h>
#include <sys/times.h>
#include <string.h>
#include "aggregate_timing.h"

#define AGGTIMING_MAX_KEYWORDS 20
#define AGGTIMING_REPORT_PERIOD 10

struct aggtiming_struct {
  char keyword[100];
  time_t clockreport;
  clock_t clicksreport;
  clock_t usedclicks;
  unsigned callcount;

  clock_t last_timing_start;
};

static struct aggtiming_struct aggtiming_data[AGGTIMING_MAX_KEYWORDS];
static int aggtiming_num_keywords = 0;


static clock_t get_hires_clicks() {
#if 1
  struct tms dummy;
  return (unsigned long) times(&dummy);
#elif 0
  struct rusage ru;
  getrusage(RUSAGE_SELF, &ru);
  return (ru.ru_utime.sec*1000000 + ru.ru_utime.usec);
#else
  return clock();
#endif
}


void aggregate_timing_start(const char *keyword)
{
  int i;
  for (i = 0; i < AGGTIMING_MAX_KEYWORDS; i++) {
    if (i >= aggtiming_num_keywords) {
      // did not find the keyword, so add a new record.

      //fprintf(stderr, "adding timing for %s\n", keyword);
      if (strlen(keyword) >= sizeof(aggtiming_data[i].keyword)) {
	break;
      }

      // initialize the new record.
      strcpy(aggtiming_data[i].keyword, keyword);
      aggtiming_data[i].clockreport = time(NULL);
      aggtiming_data[i].last_timing_start = 
	aggtiming_data[i].clicksreport = get_hires_clicks();
      aggtiming_data[i].usedclicks = 0;
      aggtiming_data[i].callcount = 0;

      aggtiming_num_keywords++;
      break;

    } else if (strcmp(aggtiming_data[i].keyword, keyword) == 0) {
      // found the keyword, so start timing.
      aggtiming_data[i].last_timing_start = get_hires_clicks();
      break;
    }
  }
}


void aggregate_timing_stop(const char *keyword)
{
  int i;
  for (i = 0; i < aggtiming_num_keywords; i++) {
    if (strcmp(aggtiming_data[i].keyword, keyword) == 0) {
      // found the keyword, so stop timing.
      clock_t stopclicks = get_hires_clicks();
      time_t stopclock = time(NULL);

      // periodically print out the statistics.
      if (aggtiming_data[i].clockreport < stopclock || stopclock - aggtiming_data[i].clockreport > AGGTIMING_REPORT_PERIOD) {
	clock_t elapsedclicks = stopclicks - aggtiming_data[i].clicksreport;
	long clickspercall = (aggtiming_data[i].callcount > 0 ? aggtiming_data[i].usedclicks / aggtiming_data[i].callcount : 0);
	fprintf(stderr, "%s consumed %ld of %ld clicks over %u calls (%.2f%%, %ld/call)\n",
		keyword, 
		(long) aggtiming_data[i].usedclicks, 
		(long) elapsedclicks, 
		(unsigned) aggtiming_data[i].callcount,
		(aggtiming_data[i].usedclicks * 100.0 / elapsedclicks), 
		(long) clickspercall);

	// reset the statistics
	aggtiming_data[i].clockreport = stopclock;
	aggtiming_data[i].clicksreport = stopclicks;
	aggtiming_data[i].callcount = 0;
	aggtiming_data[i].usedclicks = 0;
      }

      // update the consumed time, if there was a matching call to aggregate_timing_start.
      if (aggtiming_data[i].last_timing_start != 0) {
	aggtiming_data[i].usedclicks += (stopclicks - aggtiming_data[i].last_timing_start);
	aggtiming_data[i].callcount++;
	aggtiming_data[i].last_timing_start = 0;

	//fprintf(stderr, "updating timing for %s\n", keyword);

      }
      break;
    }
  }
}

