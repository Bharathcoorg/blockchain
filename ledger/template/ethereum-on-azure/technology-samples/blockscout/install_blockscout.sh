#!/bin/bash

# Update Explorer Configuration Files

# Install NPM Dependencies
cd apps/block_scout_web/assets && sudo npm install --unsafe-perm; cd -
cd apps/explorer && sudo npm install --unsafe-perm; cd -

# NPM Deploy
cd apps/block_scout_web/assets && sudo npm run-script deploy; cd -

# Create systemd Service File
cd ../../../etc/systemd/system
echo "
	[Unit]
	Description=Edgeware Explorer

	[Service]
	Type=simple
	User=$USER
	Group=$USER
	Restart=on-failure
	Environment=MIX_ENV=prod
	Environment=LANG=en_US.UTF-8
	WorkingDirectory=/home/$USER/blockscout
	ExecStart=/usr/local/bin/mix phx.server

	[Install]
	WantedBy=multi-user.target
" | sudo tee blockscout.service
cd -

# Edit nginx Configuration File
cd ../../../etc/nginx
echo "
	events {
		worker_connections  1024;
	}

	http {
		server {
		    listen 80;
			server_name \"\";

			location / {
				proxy_pass http://localhost:4000;
				proxy_http_version 1.1;
				proxy_redirect off;
				proxy_set_header X-Real-IP \$remote_addr;
				proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
				proxy_set_header Host \$host;
				proxy_set_header Upgrade \$http_upgrade;
				proxy_set_header Connection \"upgrade\";
			}
		}
	}
" | sudo tee nginx.conf
cd -
sudo service nginx reload

# Start systemd Service
sudo systemctl daemon-reload
sudo systemctl start blockscout.service
