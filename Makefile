SHELL := bash

JAVAC := javac
JAVA_FILES := $(wildcard jmate/lang/*.java jmate/io/*.java java/lang/*.java java/io/*.java)
CLASS_FILES := $(JAVA_FILES:.java=.class)
TEST_JAVA_FILES := $(wildcard tests/*.java)
TEST_CLASS_FILES := $(TEST_JAVA_FILES:.java=.test)
HS_FILES := $(shell ls Compiler/Mate/{Frontend/,Backend/,Runtime/,}*.hs)
HS_BOOT := $(shell ls Compiler/Mate/Runtime/*.hs-boot)
BUILD := build
B_RELEASE := $(BUILD)/release
B_STATIC := $(BUILD)/static
B_COVERAGE := $(BUILD)/coverage
B_DEBUG := $(BUILD)/debug
B_QUICKCHECK := $(BUILD)/B_QUICKCHECK
PACKAGES_ := bytestring harpy hs-java plugins hoopl
PACKAGES := $(addprefix -package ,$(PACKAGES_))


GHC_CPP := -DARCH_X86

GHC_OPT  = -I. -O0 -Wall -fno-warn-unused-do-bind -fwarn-tabs
# TODO: define this in cabal... (see cpu package @ hackage)
# see *.gdb target. also useful for profiling (-p at call)
GHC_OPT += -rtsopts # -prof -auto-all
GHC_OPT += $(GHC_CPP)

# dunno anymore? some linker stuff regarding GHCi
GHC_LD := -optl-Xlinker -optl-x


.PHONY: all tests clean ghci hlint quickcheck

all: mate

%: %.class mate
	./mate $(basename $<)


tests: mate $(TEST_JAVA_FILES:.java=.class) $(TEST_CLASS_FILES)

CALLF = $(basename $@).call
testcase = ./tools/openjdktest.sh "$(1) $(basename $@)"
%.test: %.class mate
	@if [ -f $(CALLF) ]; \
		then $(call testcase,`cat $(CALLF)`); \
		else $(call testcase, ); fi

COMPILEF = $(basename $@).compile
%.class: %.java
	@if [ -f $(COMPILEF) ]; \
		then $(SHELL) $(COMPILEF); \
		else $(JAVAC) $(JAVA_FILES) $<; fi
	@echo "JAVAC $<"

ffi/native.o: ffi/native.c
	ghc -Wall -O2 -c $< -o $@

runtime: jmate/lang/MateRuntime.java
	javac jmate/lang/MateRuntime.java
	javah  -o rts/mock/jmate_lang_MateRuntime.h jmate.lang.MateRuntime
	gcc -shared -fPIC -I$(JAVA_HOME)/include rts/mock/jmate_lang_MateRuntime.c -I./rts/mock -o rts/mock/libMateRuntime.so 

GHCCALL = ghc --make $(GHC_OPT) Mate.hs ffi/trap.c -o $@ $(GHC_LD) -outputdir
mate: Mate.hs ffi/trap.c $(HS_FILES) $(HS_BOOT) ffi/native.o $(CLASS_FILES)
	@mkdir -p $(B_RELEASE)
	$(GHCCALL) $(B_RELEASE) -dynamic

mate.static: Mate.hs ffi/trap.c $(HS_FILES) $(HS_BOOT) ffi/native.o $(CLASS_FILES)
	@mkdir -p $(B_STATIC)
	$(GHCCALL) $(B_STATIC) -static

mate.hpc: Mate.hs ffi/trap.c $(HS_FILES) $(HS_BOOT) ffi/native.o $(CLASS_FILES)
	@mkdir -p $(B_COVERAGE)
	@mkdir -p $(B_COVERAGE)/tix/tests
	$(GHCCALL) $(B_COVERAGE) -static -fhpc

quickcheck: mate.quickcheck
	@./$<

mate.quickcheck: Compiler/Mate/QuickCheck.hs ffi/trap.c $(HS_FILES) $(HS_BOOT) ffi/native.o $(CLASS_FILES)
	@mkdir -p $(B_QUICKCHECK)
	ghc --make -O2 Compiler/Mate/QuickCheck.hs -o $@ -outputdir $(B_QUICKCHECK)


# see http://www.haskell.org/ghc/docs/7.0.4/html/users_guide/hpc.html
TIX_FILES := $(addprefix $(B_COVERAGE)/tix/,$(TEST_JAVA_FILES:.java=.tix))
coverage: mate.hpc $(TIX_FILES)
	@hpc sum $(TIX_FILES) --output=$(B_COVERAGE)/coverage.tix
	@hpc report $(B_COVERAGE)/coverage.tix
	@mkdir -p $(B_COVERAGE)/html > /dev/null
	@hpc markup $(B_COVERAGE)/coverage.tix --destdir=$(B_COVERAGE)/html > /dev/null
	@echo "see ./$(B_COVERAGE)/html for a HTML report"

CALLHPX = $(basename $<).call
matehpc = ./mate.hpc $(1) $(basename $<) > /dev/null
# call it only with -j1 !
$(B_COVERAGE)/tix/%.tix: %.class mate.hpc
	@echo "doing coverage of $(basename $<)..."
	@rm -rf mate.hpc.tix
	@if [ -f $(CALLHPX) ]; \
		then $(call matehpc,`cat $(CALLHPX)`); \
		else $(call matehpc,); fi
	@mv mate.hpc.tix $@

%.gdb: %.class mate
	gdb -x .gdbcmds -q --args mate $(basename $<) +RTS -V0 --install-signal-handlers=no

clean:
	rm -rf $(BUILD) mate mate.static ffi/native.o \
		tests/*.class Mate/*_stub.* \
		$(CLASS_FILES) \
		scratch/*.class \
		.hpc all.tix \
		mate.quickcheck

ghci: mate.static
	ghci -I. -fobject-code $(PACKAGES) -outputdir $(B_STATIC) Mate.hs $(GHC_CPP)

tags: mate.static
	@# @-fforce-recomp, see
	@# http://stackoverflow.com/questions/7137414/how-do-i-force-interpretation-in-hint
	@# @-fobject-code: force to generate native code (necessary for ffi stuff)
	ghc -I. -fforce-recomp -fobject-code $(PACKAGES) Mate.hs -outputdir $(B_STATIC) -e :ctags $(GHC_CPP)

hlint:
	hlint Mate.hs Compiler/Mate/

scratch: mate $(wildcard jmate/lang/*.java) scratch/GCTest.java
	javac $(wildcard jmate/lang/*.java)
	javac scratch/GCTest.java
	./mate scratch.GCTest  
