.PHONY: all server client clean install

all: server client

server:
	cd server && npm install && npm run build

client:
	cd client && swift build -c release --disable-sandbox

clean:
	cd server && rm -rf dist node_modules
	cd client && swift package clean

install: all
	@echo "Installing server..."
	cp server/dist/index.js /usr/local/lib/openclaw-activity-server/
	@echo "Installing client..."
	cp client/.build/release/OpenClawActivity /usr/local/bin/openclaw-activity-bar
	@echo "Done. Run 'openclaw-activity-server' and 'openclaw-activity-bar'"

dev-server:
	cd server && npm run dev

dev-client:
	cd client && swift run
