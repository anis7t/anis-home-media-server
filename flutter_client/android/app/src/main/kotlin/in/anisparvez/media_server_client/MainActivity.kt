package `in`.anisparvez.media_server_client

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun getInitialRoute(): String? {
        val route = intent.getStringExtra("route")
        if (!route.isNullOrBlank()) {
            return if (route.startsWith("/")) route else "/$route"
        }
        return super.getInitialRoute()
    }

    override fun getDartEntrypointArgs(): List<String> {
        val args = ArrayList(super.getDartEntrypointArgs() ?: emptyList())
        val route = intent.getStringExtra("route")
        if (!route.isNullOrBlank()) {
            args.add("--route=$route")
            if (route.contains("player")) {
                args.add("--player")
            }
        }
        if (intent.getBooleanExtra("player", false)) {
            args.add("--player")
        }
        val server = intent.getStringExtra("server")
        if (!server.isNullOrBlank()) {
            args.add("--server=$server")
        }
        val mediaUrl = intent.getStringExtra("mediaUrl")
        if (!mediaUrl.isNullOrBlank()) {
            args.add("--media-url=$mediaUrl")
        }
        return args
    }
}
