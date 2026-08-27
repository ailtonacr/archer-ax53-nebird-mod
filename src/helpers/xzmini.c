#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <lzma.h>

static unsigned char inbuf[32768];
static unsigned char outbuf[32768];

static int write_all(const unsigned char *buf, size_t len)
{
    while (len != 0) {
        ssize_t n = write(STDOUT_FILENO, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        buf += n;
        len -= (size_t)n;
    }
    return 0;
}

int main(void)
{
    lzma_stream strm = LZMA_STREAM_INIT;
    lzma_ret ret = lzma_stream_decoder(&strm, UINT64_MAX,
                                       LZMA_CONCATENATED);
    if (ret != LZMA_OK) {
        dprintf(STDERR_FILENO, "xzmini: decoder init failed: %d\n", ret);
        return 2;
    }

    lzma_action action = LZMA_RUN;
    for (;;) {
        if (strm.avail_in == 0 && action != LZMA_FINISH) {
            ssize_t n = read(STDIN_FILENO, inbuf, sizeof(inbuf));
            if (n < 0) {
                if (errno == EINTR) continue;
                dprintf(STDERR_FILENO, "xzmini: read: %s\n", strerror(errno));
                lzma_end(&strm);
                return 1;
            }
            strm.next_in = inbuf;
            strm.avail_in = (size_t)n;
            if (n == 0) action = LZMA_FINISH;
        }

        strm.next_out = outbuf;
        strm.avail_out = sizeof(outbuf);
        ret = lzma_code(&strm, action);
        size_t produced = sizeof(outbuf) - strm.avail_out;
        if (produced != 0 && write_all(outbuf, produced) != 0) {
            dprintf(STDERR_FILENO, "xzmini: write: %s\n", strerror(errno));
            lzma_end(&strm);
            return 1;
        }

        if (ret == LZMA_STREAM_END) break;
        if (ret != LZMA_OK) {
            dprintf(STDERR_FILENO, "xzmini: decode failed: %d\n", ret);
            lzma_end(&strm);
            return 1;
        }
    }

    lzma_end(&strm);
    return 0;
}
