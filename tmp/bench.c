#include <stdio.h>      /* for printf() and fprintf() */
#include <sys/socket.h> /* for socket(), connect(), send(), and recv() */
#include <arpa/inet.h>  /* for sockaddr_in and inet_addr() */
#include <stdlib.h>     /* for atoi() and exit() */
#include <string.h>     /* for memset() */
#include <unistd.h>     /* for close() */
#include <errno.h>     /* for close() */

#include <stdint.h>
#include <sys/time.h>
#include <sys/types.h>
#include <time.h>

#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>
#include <time.h>


#define MYDEBUG
#ifdef MYDEBUG
#define debug(fmt, ...)   do{ \
	fprintf(stderr, "%s:%d: ", __FILE__, __LINE__); \
	fprintf(stderr, fmt, ##__VA_ARGS__); \
	if (fmt[strlen(fmt) - 1] != 0x0a) { fprintf(stderr, "\n"); } \
	} while(0)
#else
#define debug(...)
#endif

#define warn(fmt, ...)   do{ \
	fprintf(stderr, "[WARN] %s:%d: ", __FILE__, __LINE__); \
	fprintf(stderr, fmt, ##__VA_ARGS__); \
	if (fmt[strlen(fmt) - 1] != 0x0a) { fprintf(stderr, "\n"); } \
} while(0)


#define die(fmt, ...)   do{ \
	fprintf(stderr, "[DIED] %s:%d: ", __FILE__, __LINE__); \
	fprintf(stderr, fmt, ##__VA_ARGS__); \
	if (fmt[strlen(fmt) - 1] != 0x0a) { fprintf(stderr, "\n"); } \
	exit(255);\
} while(0)

typedef struct {
	uint32_t      type;
	uint32_t      len;
	uint32_t      seq;
	char          data[16];
} mypacket;

typedef struct {
	uint32_t      type;
	uint32_t      len;
	uint32_t      seq;
	char          code;
	char          data[2048];
} inpacket;

int main () {
	mypacket pk;
	inpacket in;
	
	int sock;
	struct sockaddr_in addr, peer;
	socklen_t addrlen = sizeof(peer);
	struct timespec tv;
	uint64_t start, time;
	
	memset(&addr, 0, sizeof(addr));
	
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = inet_addr("0.0.0.0");
	addr.sin_port        = htons(3334);
	
	if ((sock = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP)) < 0)
		die("socket failed: %s", strerror(errno));
		
	if (connect(sock, (struct sockaddr *) &addr, sizeof(addr)) < 0)
		die("connect failed: %s", strerror(errno));
	
	if( getpeername( sock, ( struct sockaddr *)&peer, &addrlen) < 0 )
		die("getpeername ailed: %s", strerror(errno));
	
	warn("connected address: %s:%d",  inet_ntoa( peer.sin_addr ), ntohs( peer.sin_port ) );
	
	//fcntl(r->s, F_SETFL, O_NONBLOCK | O_RDWR);
	
	memset(&pk, 0, sizeof(pk));
	pk.type = 1;
	pk.len = sizeof(pk.data);
	pk.seq++;
	memcpy(&pk.data,"mons@cpan.org",16);
	int i;
	clock_gettime(0, &tv);
	start = tv.tv_sec * 1E9 + tv.tv_nsec;
	
	while(1) {
		i++;
		pk.seq++;
		if( send(sock, &pk, sizeof(pk), 0) != sizeof(pk) )
			die ("send failed: %s",strerror(errno));
		if( recv(sock, &in, sizeof(in), 0) < 0 )
			die ("recv failed: %s",strerror(errno));
		if (i % 10000 == 0) {
			clock_gettime(0, &tv);
			time = tv.tv_sec * 1E9 + tv.tv_nsec;
			long double delta = (double)(time - start)/1E9;
			
			printf("i=%d, rate=%0.2Lf/s\n", i, (double)i / delta);
		}
	}

	printf("ok\n");
}