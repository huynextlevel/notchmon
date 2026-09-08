.PHONY: vendor build run app release icon dmg dmg-bg clean probe

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

# The installer window. `dmg` needs a built app; `dmg-bg` re-renders the
# artwork and needs librsvg, which is why its output is committed.
dmg: app
	./Scripts/make-dmg.sh $(BUILD)

dmg-bg:
	./Scripts/make-dmg-bg.sh

run: app
	killall NotchMon 2>/dev/null || true
	open dist/NotchMon.app

clean:
	rm -rf .build dist
