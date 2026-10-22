all: install

SRCS := Cargo.toml Cargo.lock src/main.rs

NATIVE_PATH=target/release/lepton-mdns-publish
$(NATIVE_PATH): $(SRCS)
	@cargo build --release

TARGET_PATH=target/aarch64-unknown-linux-gnu/release/lepton-mdns-publish
$(TARGET_PATH): $(SRCS)
	@CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc \
	cargo build --target=aarch64-unknown-linux-gnu --profile=release

bin:
	mkdir -p $@
bin/lepton-mdns-publish: $(TARGET_PATH) | bin
	@install -Dm755 -v $< $@
install: bin/lepton-mdns-publish

clean:
	cargo clean
