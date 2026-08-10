import Foundation

struct CatalogPort: Hashable {
	var containerPort: Int
	var suggestedHostPort: Int
	var label: String
	/// Whether portless can meaningfully route it — portless is an HTTP proxy, so
	/// a Postgres wire port gets a name that would never serve.
	var isHTTP: Bool

	init(_ containerPort: Int, host: Int? = nil, label: String = "", isHTTP: Bool = true) {
		self.containerPort = containerPort
		suggestedHostPort = host ?? containerPort
		self.label = label
		self.isHTTP = isHTTP
	}
}

struct CatalogApp: Identifiable, Hashable {
	var id: String
	var name: String
	var image: String
	var blurb: String
	var category: String
	var symbol: String
	var ports: [CatalogPort]
	var env: [EnvEntry] = []
	var volumes: [String] = []
	var command: String = ""
	/// What this app exports to services that depend on it.
	var providedEnv: [EnvEntry] = []

	var primaryPort: CatalogPort? { ports.first }

	var isWeb: Bool { ports.first?.isHTTP ?? false }

	static func env(_ pairs: [(String, String)]) -> [EnvEntry] {
		pairs.map { EnvEntry(key: $0.0, value: $0.1) }
	}
}

enum Catalog {
	static let categories = ["Apps", "Databases", "Infrastructure", "AI"]

	/// Volume strings use `{{name}}`, expanded to the container name so two
	/// containers from the same image never share a volume.
	static let apps: [CatalogApp] = [
		CatalogApp(
			id: "excalidraw",
			name: "Excalidraw",
			image: "excalidraw/excalidraw:latest",
			blurb: "Virtual whiteboard for hand-drawn style diagrams.",
			category: "Apps",
			symbol: "scribble.variable",
			ports: [CatalogPort(80, host: 8080, label: "Web")]
		),
		CatalogApp(
			id: "it-tools",
			name: "IT Tools",
			image: "corentinth/it-tools:latest",
			blurb: "Handy developer utilities — encoders, converters, generators.",
			category: "Apps",
			symbol: "wrench.and.screwdriver.fill",
			ports: [CatalogPort(80, host: 8081, label: "Web")]
		),
		CatalogApp(
			id: "drawio",
			name: "draw.io",
			image: "jgraph/drawio:latest",
			blurb: "Diagram editor for flowcharts and architecture.",
			category: "Apps",
			symbol: "flowchart.fill",
			ports: [CatalogPort(8080, host: 8082, label: "Web")]
		),
		CatalogApp(
			id: "stirling-pdf",
			name: "Stirling PDF",
			image: "frooodle/s-pdf:latest",
			blurb: "Local PDF toolkit — merge, split, OCR, convert.",
			category: "Apps",
			symbol: "doc.richtext",
			ports: [CatalogPort(8080, host: 8083, label: "Web")]
		),
		CatalogApp(
			id: "uptime-kuma",
			name: "Uptime Kuma",
			image: "louislam/uptime-kuma:1",
			blurb: "Self-hosted uptime monitoring with status pages.",
			category: "Apps",
			symbol: "waveform.path.ecg",
			ports: [CatalogPort(3001, label: "Web")],
			volumes: ["{{name}}-data:/app/data"]
		),
		CatalogApp(
			id: "n8n",
			name: "n8n",
			image: "n8nio/n8n:latest",
			blurb: "Workflow automation with a visual node editor.",
			category: "Apps",
			symbol: "point.3.connected.trianglepath.dotted",
			ports: [CatalogPort(5678, label: "Web")],
			volumes: ["{{name}}-data:/home/node/.n8n"]
		),
		CatalogApp(
			id: "gitea",
			name: "Gitea",
			image: "gitea/gitea:latest",
			blurb: "Lightweight self-hosted Git service.",
			category: "Apps",
			symbol: "arrow.triangle.branch",
			ports: [CatalogPort(3000, host: 3010, label: "Web"), CatalogPort(22, host: 2222, label: "SSH", isHTTP: false)],
			volumes: ["{{name}}-data:/data"]
		),
		CatalogApp(
			id: "nocodb",
			name: "NocoDB",
			image: "nocodb/nocodb:latest",
			blurb: "Airtable-style UI over any database.",
			category: "Apps",
			symbol: "tablecells.fill",
			ports: [CatalogPort(8080, host: 8084, label: "Web")],
			volumes: ["{{name}}-data:/usr/app/data"]
		),
		CatalogApp(
			id: "mailpit",
			name: "Mailpit",
			image: "axllent/mailpit:latest",
			blurb: "Catches outgoing dev email and shows it in a web inbox.",
			category: "Infrastructure",
			symbol: "envelope.fill",
			ports: [CatalogPort(8025, label: "Web"), CatalogPort(1025, label: "SMTP", isHTTP: false)],
			providedEnv: CatalogApp.env([
				("SMTP_HOST", "{{host}}"),
				("SMTP_PORT", "{{port:1025}}"),
			])
		),
		CatalogApp(
			id: "adminer",
			name: "Adminer",
			image: "adminer:latest",
			blurb: "Single-file database admin UI.",
			category: "Infrastructure",
			symbol: "cylinder.split.1x2.fill",
			ports: [CatalogPort(8080, host: 8085, label: "Web")]
		),
		CatalogApp(
			id: "portainer",
			name: "Portainer",
			image: "portainer/portainer-ce:latest",
			blurb: "Web UI for managing Docker itself.",
			category: "Infrastructure",
			symbol: "shippingbox.fill",
			ports: [CatalogPort(9000, host: 9010, label: "Web")],
			volumes: ["/var/run/docker.sock:/var/run/docker.sock", "{{name}}-data:/data"]
		),
		CatalogApp(
			id: "minio",
			name: "MinIO",
			image: "minio/minio:latest",
			blurb: "S3-compatible object storage.",
			category: "Infrastructure",
			symbol: "externaldrive.fill",
			ports: [CatalogPort(9001, host: 9011, label: "Console"), CatalogPort(9000, host: 9012, label: "S3 API")],
			env: CatalogApp.env([
				("MINIO_ROOT_USER", "minioadmin"),
				("MINIO_ROOT_PASSWORD", "minioadmin"),
			]),
			volumes: ["{{name}}-data:/data"],
			command: "server /data --console-address :9001",
			providedEnv: CatalogApp.env([
				("S3_ENDPOINT", "http://{{host}}:{{port:9000}}"),
				("S3_ACCESS_KEY", "minioadmin"),
				("S3_SECRET_KEY", "minioadmin"),
			])
		),
		CatalogApp(
			id: "postgres",
			name: "PostgreSQL",
			image: "postgres:18",
			blurb: "The default relational database.",
			category: "Databases",
			symbol: "cylinder.fill",
			ports: [CatalogPort(5432, label: "Postgres", isHTTP: false)],
			env: CatalogApp.env([
				("POSTGRES_USER", "postgres"),
				("POSTGRES_PASSWORD", "postgres"),
				("POSTGRES_DB", "app"),
			]),
			volumes: ["{{name}}-data:/var/lib/postgresql/data"],
			providedEnv: CatalogApp.env([
				("DATABASE_URL", "postgres://postgres:postgres@{{host}}:{{port:5432}}/app"),
				("PGHOST", "{{host}}"),
				("PGPORT", "{{port:5432}}"),
			])
		),
		CatalogApp(
			id: "redis",
			name: "Redis",
			image: "redis:8-alpine",
			blurb: "In-memory cache and message broker.",
			category: "Databases",
			symbol: "bolt.fill",
			ports: [CatalogPort(6379, label: "Redis", isHTTP: false)],
			volumes: ["{{name}}-data:/data"],
			providedEnv: CatalogApp.env([
				("REDIS_URL", "redis://{{host}}:{{port:6379}}"),
			])
		),
		CatalogApp(
			id: "mongo",
			name: "MongoDB",
			image: "mongo:8",
			blurb: "Document database.",
			category: "Databases",
			symbol: "leaf.fill",
			ports: [CatalogPort(27_017, label: "Mongo", isHTTP: false)],
			volumes: ["{{name}}-data:/data/db"],
			providedEnv: CatalogApp.env([
				("MONGO_URL", "mongodb://{{host}}:{{port:27017}}"),
			])
		),
		CatalogApp(
			id: "rabbitmq",
			name: "RabbitMQ",
			image: "rabbitmq:4-management",
			blurb: "Message broker with a management UI.",
			category: "Infrastructure",
			symbol: "arrow.left.arrow.right",
			ports: [CatalogPort(15_672, label: "Management"), CatalogPort(5672, label: "AMQP", isHTTP: false)],
			volumes: ["{{name}}-data:/var/lib/rabbitmq"],
			providedEnv: CatalogApp.env([
				("AMQP_URL", "amqp://guest:guest@{{host}}:{{port:5672}}"),
			])
		),
		CatalogApp(
			id: "meilisearch",
			name: "Meilisearch",
			image: "getmeili/meilisearch:v1.11",
			blurb: "Fast full-text search engine.",
			category: "Databases",
			symbol: "magnifyingglass",
			ports: [CatalogPort(7700, label: "API")],
			volumes: ["{{name}}-data:/meili_data"],
			providedEnv: CatalogApp.env([
				("MEILI_URL", "http://{{host}}:{{port:7700}}"),
			])
		),
		CatalogApp(
			id: "qdrant",
			name: "Qdrant",
			image: "qdrant/qdrant:latest",
			blurb: "Vector database for embeddings and semantic search.",
			category: "AI",
			symbol: "point.3.filled.connected.trianglepath.dotted",
			ports: [CatalogPort(6333, label: "REST"), CatalogPort(6334, label: "gRPC", isHTTP: false)],
			volumes: ["{{name}}-data:/qdrant/storage"],
			providedEnv: CatalogApp.env([
				("QDRANT_URL", "http://{{host}}:{{port:6333}}"),
			])
		),
		CatalogApp(
			id: "open-webui",
			name: "Open WebUI",
			image: "ghcr.io/open-webui/open-webui:main",
			blurb: "Chat front-end for local and hosted LLMs.",
			category: "AI",
			symbol: "bubble.left.and.text.bubble.right.fill",
			ports: [CatalogPort(8080, host: 8086, label: "Web")],
			volumes: ["{{name}}-data:/app/backend/data"]
		),
		CatalogApp(
			id: "grafana",
			name: "Grafana",
			image: "grafana/grafana:latest",
			blurb: "Dashboards and visualisation for metrics.",
			category: "Infrastructure",
			symbol: "chart.xyaxis.line",
			ports: [CatalogPort(3000, host: 3020, label: "Web")],
			volumes: ["{{name}}-data:/var/lib/grafana"]
		),
	]

	static func app(id: String) -> CatalogApp? {
		apps.first { $0.id == id }
	}

	static func grouped() -> [(String, [CatalogApp])] {
		categories.compactMap { category in
			let matching = apps.filter { $0.category == category }
			return matching.isEmpty ? nil : (category, matching)
		}
	}

	static func expand(volume: String, containerName: String) -> String {
		volume.replacingOccurrences(of: "{{name}}", with: containerName)
	}
}
