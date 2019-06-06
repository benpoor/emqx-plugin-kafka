## shallow clone for speed

DEPS = brod supervisor3
dep_brod = git https://github.com/klarna/brod 3.7.9
dep_supervisor3  = git-emqx https://github.com/klarna/supervisor3 1.1.8

REBAR_GIT_CLONE_OPTIONS += --depth 1
export REBAR_GIT_CLONE_OPTIONS

REBAR = rebar3
all: compile

compile:
	$(REBAR) compile

ct: compile
	$(REBAR) as test ct -v

eunit: compile
	$(REBAR) as test eunit

xref:
	$(REBAR) xref

clean: distclean

distclean:
	@rm -rf _build
	@rm -f data/app.*.config data/vm.*.args rebar.lock