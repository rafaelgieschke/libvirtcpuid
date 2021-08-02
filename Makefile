INTERPOSED_LD_PATH ?= /lib64/ld-linux-x86-64.so.2.orig
LD_INJECT_ENV_PATH ?= /etc/ld-inject.env
MUSL_VERSION ?= 1.1.24
MUSL_ARCHIVE ?= musl-$(MUSL_VERSION).tar.gz

# We build both a loader and a shared library (DSO)

#############################
### Common flags
CFLAGS += -std=c99 -g -O2 -fPIC -pie -fno-stack-protector
CFLAGS += -fdata-sections -ffunction-sections # allow removing unused code
# We don't want to export any symbols by default. we use our LIB_EXPORT macro if we need otherwise.
CFLAGS += -fvisibility=hidden
# These are the warnings musl uses. We keep the same as we compile their sources.
CFLAGS += -Werror=implicit-function-declaration -Werror=implicit-int -Werror=pointer-sign -Werror=pointer-arith
CFLAGS += -D_GNU_SOURCE

LDFLAGS += -fPIC -pie
LDFLAGS += -Wl,--gc-sections # remove unused code

#############################
### Loader flags
ARCH = x86_64
CFLAGS_LD += -nostdinc # we use musl for the loader, not glibc
# These are musl includes. Order matters.
CFLAGS_LD += -D_GNU_SOURCE \
	-Imusl/arch/$(ARCH) \
	-Imusl/arch/generic \
	-Imusl/obj/src/internal \
	-Imusl/src/include \
	-Imusl/src/internal \
	-Imusl/obj/include \
	-Imusl/include

LDFLAGS_LD += -shared # needed so that our interpreter can load static and dynamic executables
LDFLAGS_LD += -nostdlib -Wl,--exclude-libs,ALL # we don't export any symbols from musl
LDFLAGS_LD += -Wl,-z,defs # complain about undefined symbols
LDFLAGS_LD += -Wl,-e_dlstart

#############################
### DSO flags
LDFLAGS_DSO += -shared -ldl


#############################
### Dependencies
CONFIG_H = src/config.h

AUTOGEN_DEPS = src/linux/capflags.c $(CONFIG_H)

DEPS = $(wildcard src/*.h) $(wildcard src/linux/*) $(wildcard src/gcc/*) $(AUTOGEN_DEPS) musl/lib/libc.a

TARGET_LD = ld-virtcpuid.so
TARGET_DSO = libvirtcpuid.so
TARGET_FEATURES_JSON = lcd_mask/features.json
TARGET_FEATURES_JSON_GEN = lcd_mask/features_gen

OBJECTS_LD = build/ld/loader.o \
	     build/ld/cpuid.o

OBJECTS_DSO = build/dso/dso_signal.o \
	      build/dso/cpuid.o

OBJECTS_LCD_MASK_FEATURES_GEN = lcd_mask/features_gen.o

all: $(TARGET_DSO) $(TARGET_LD) $(TARGET_FEATURES_JSON) LD_PRELOAD_dlsym.so;

build/ld:
	mkdir -p $@

build/dso:
	mkdir -p $@

$(MUSL_ARCHIVE):
	wget https://musl.libc.org/releases/$@

musl: $(MUSL_ARCHIVE)
	rm -rf musl.tmp
	mkdir musl.tmp
	tar xzf $(MUSL_ARCHIVE) -C musl.tmp --strip-components=1
	mv musl.tmp musl

musl/lib/libc.a: musl
	cd musl && ./configure --disable-shared
	+make -C musl

$(TARGET_LD): $(OBJECTS_LD) musl/lib/libc.a
	$(CC) $^ $(LDFLAGS) $(LDFLAGS_LD) -o $@

$(TARGET_DSO): $(OBJECTS_DSO)
	$(CC) $^ $(LDFLAGS) $(LDFLAGS_DSO) -o $@

LD_PRELOAD_%.so: LD_PRELOAD_%.c
	$(CC) $^ $(LDFLAGS) $(LDFLAGS_DSO) -o $@

$(TARGET_FEATURES_JSON_GEN): $(OBJECTS_LCD_MASK_FEATURES_GEN)
	$(CC) $^ -o $@

$(TARGET_FEATURES_JSON): $(TARGET_FEATURES_JSON_GEN)
	$< $@

src/linux/capflags.c: src/linux/cpufeatures.h src/linux/mkcapflags.sh
	sh src/linux/mkcapflags.sh $< $@

build/ld/%.o: src/%.c $(DEPS) | build/ld
	$(CC) -c $(CFLAGS) $(CFLAGS_LD) $< -o $@

build/dso/%.o: src/%.c $(DEPS) | build/dso
	$(CC) -c $(CFLAGS) $(CFLAGS_DSO) $< -o $@

%.o: %.c $(DEPS)
	$(CC) -c $(CFLAGS) $< -o $@

.PHONY: gen_config # can depend on env vars, so it must always be checked
gen_config:
	@echo "// Autogenerated by Makefile" > $(CONFIG_H).tmp
	@echo "#ifndef CONFIG_H" >> $(CONFIG_H).tmp
	@echo "#define CONFIG_H" >> $(CONFIG_H).tmp
	@echo "#define INTERPOSED_LD_PATH \"$(INTERPOSED_LD_PATH)\"" >> $(CONFIG_H).tmp
	@echo "#define LD_INJECT_ENV_PATH \"$(LD_INJECT_ENV_PATH)\"" >> $(CONFIG_H).tmp
	@echo "#endif" >> $(CONFIG_H).tmp
	@cmp $(CONFIG_H) $(CONFIG_H).tmp > /dev/null 2>&1 \
		|| (echo "Generating config.h" && mv $(CONFIG_H).tmp $(CONFIG_H))
	@rm -f $(CONFIG_H).tmp

$(CONFIG_H): gen_config;

.PHONY: clean
clean:
	rm -rf build $(TARGET_DSO) $(TARGET_LD) \
		$(TARGET_FEATURES_JSON) $(TARGET_FEATURES_JSON_GEN) \
		$(OBJECTS_LD) \
		$(OBJECTS_DSO) \
		$(OBJECTS_LCD_MASK_FEATURES_GEN) \
		$(AUTOGEN_DEPS) musl.tmp
