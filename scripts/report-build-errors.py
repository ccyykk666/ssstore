"""Keep compiler output visible and surface fresh build errors in check annotations."""
import re
import sys


def annotation(line):
    if not re.search(r"(?:^|:\s)(?:fatal )?error:", line):
        return None
    message = re.sub(r"https?://\S+", "<URL redacted>", line.strip())[:2000]
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return "::error title=Xcode build::" + message


if __name__ == "__main__":
    for line in sys.stdin:
        print(line, end="", flush=True)
        error = annotation(line)
        if error:
            print(error, flush=True)
