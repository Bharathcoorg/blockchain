#!/bin/bash

if [ $# -lt 3 ]; then
	echo "Insufficient # of parameters supplied."
	exit 1
else
	rpcRegex='(https?)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
	if [[ "$1" =~ $rpcRegex ]]; then
		echo "Valid Consortium IP Address"
	else
		echo "$(tput setaf 1)Invalid Consortium IP Address supplied."
		exit 1
	fi

	wsRegex='(wss|ws?)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]'
	if [[ "$2" =~ $wsRegex ]]; then
		echo "Valid WebSocket IP Address"
	else
		echo "$(tput setaf 1)Invalid WebSocket IP Address supplied."
		exit 1
	fi
fi

# Install Mix Dependencies
cd blockscout
sudo MIX_ENV=prod mix local.hex --force && echo "hex installed"
sudo MIX_ENV=prod mix deps.update libsecp256k1
sudo MIX_ENV=prod mix do deps.get, local.rebar --force, deps.compile, compile && echo "mix deps installed"

# Update Explorer Configuration Files
cd apps/explorer/config/prod
echo "
use Mix.Config

config :explorer,
  json_rpc_named_arguments: [
    transport: EthereumJSONRPC.HTTP,
    transport_options: [
      http: EthereumJSONRPC.HTTP.HTTPoison,
      url: \"https://edgeware.api.onfinality.io/public:8540\",
      method_to_url: [
        eth_call: \"https://edgeware.api.onfinality.io/public:8540\",
        eth_getBalance: \"https://edgeware.api.onfinality.io/public:8540\",
        trace_replayTransaction: \"https://edgeware.api.onfinality.io/public:8540\"
      ],
      http_options: [recv_timeout: :timer.minutes(1), timeout: :timer.minutes(1), hackney: [pool: :ethereum_jsonrpc]]
    ],
    variant: EthereumJSONRPC.Parity
  ],
  subscribe_named_arguments: [
    transport: EthereumJSONRPC.WebSocket,
    transport_options: [
      web_socket: EthereumJSONRPC.WebSocket.WebSocketClient,
      url: \"wss://edgeware.api.onfinality.io/public:8547\"
    ],
    variant: EthereumJSONRPC.Parity
 ]" | sudo tee parity.exs
cd -

cd apps/explorer/config
echo "
use Mix.Config

config :explorer, Explorer.Repo,
  username: \"postgres\",
  password: \"Password123\",
  database: \"explorer_test\",
  hostname: \"localhost\",
  port: \"5432\",
  #url: \"postgres:localhost:5432/explorer_test\",
  pool_size: String.to_integer(System.get_env(\"POOL_SIZE\") || \"10\"),
  #ssl: String.equivalent?(System.get_env(\"ECTO_USE_SSL\") || \"true\", \"true\"),
  prepare: :unnamed,
  timeout: :timer.seconds(60)

variant =
  if is_nil(System.get_env(\"ETHEREUM_JSONRPC_VARIANT\")) do
    \"parity\"
  else
    System.get_env(\"ETHEREUM_JSONRPC_VARIANT\")
    |> String.split(\".\")
    |> List.last()
    |> String.downcase()
  end" | sudo tee prod.exs
cd -

# Update Indexer Configuration Files
cd apps/indexer/config/prod

echo "
use Mix.Config

config :indexer,
  block_interval: :timer.seconds(5),
  json_rpc_named_arguments: [
    transport: EthereumJSONRPC.HTTP,
    transport_options: [
      http: EthereumJSONRPC.HTTP.HTTPoison,
      url: \"https://edgeware.api.onfinality.io/public:8540\",
      method_to_url: [
        eth_getBalance: \"https://edgeware.api.onfinality.io/public:8540\",
        trace_block: \"https://edgeware.api.onfinality.io/public:8540\",
        trace_replayTransaction: \"https://edgeware.api.onfinality.io/public:8540\"
      ],
      http_options: [recv_timeout: :timer.minutes(1), timeout: :timer.minutes(1), hackney: [pool: :ethereum_jsonrpc]]
    ],
    variant: EthereumJSONRPC.Parity
  ],
  subscribe_named_arguments: [
    transport: EthereumJSONRPC.WebSocket,
    transport_options: [
      web_socket: EthereumJSONRPC.WebSocket.WebSocketClient,
      url: \"wss://edgeware.api.onfinality.io/public:8547\"
    ]
  ]
" | sudo tee parity.exs
cd -

# Update Blockscout Web Configuration Files
cd apps/block_scout_web/config
echo "
use Mix.Config

config :block_scout_web, BlockScoutWeb.Endpoint,
  force_ssl: false,
  check_origin: false,
  http: [port: 4000],
  url: [
    scheme: \"http\",
    port: \"4000\",
	host: \"*.azure.com\"
  ]" | sudo tee prod.exs
cd -

# Drop Old DB (If Exists) && Create + Migrate DB
sudo MIX_ENV=prod mix do ecto.drop --no-compile --force, ecto.create --no-compile, ecto.migrate --no-compile && echo "migrated DB"

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
