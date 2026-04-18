PREFIX ?= /usr/local
BINDIR ?= $(DESTDIR)$(PREFIX)/bin
NAME    = httpserv.sh

.PHONY: test install uninstall

test:
	@./test/run.sh

install:
	@install -d $(BINDIR)
	@install -m 755 $(NAME) $(BINDIR)/$(NAME)
	@echo "installed $(NAME) -> $(BINDIR)/$(NAME)"

uninstall:
	@rm -f $(BINDIR)/$(NAME)
	@echo "removed $(BINDIR)/$(NAME)"
