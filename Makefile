.PHONY: vendor build run app release icon clean probe

vendor:
	./Scripts/vendor-tokscale.sh

build:
	swift build -c debug

app:
	./Scripts/bundle.sh release

# Needs a Developer ID certificate and stored notary credentials — see the
# header of Scripts/release.sh.
release:
	./Scripts/release.sh $(BUILD)

icon:
	./Scripts/make-icon.sh

run: app
	killall NotchMon 2>/dev/null || true
	open dist/NotchMon.app

clean:
	rm -rf .build dist
