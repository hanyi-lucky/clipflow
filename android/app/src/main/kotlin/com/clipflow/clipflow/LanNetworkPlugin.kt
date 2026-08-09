package com.clipflow.clipflow

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * LAN 网络原生插件（Android）：NsdManager 广告 + 发现。
 *
 * MethodChannel `clipflow/lan_network`：advertise / browse / stopAll / isSupported
 * EventChannel `clipflow/lan_network_events`：发现结果 `{name, host, port, txt}`
 *
 * 广告（advertise）与发现（browse）可共存：同进程既广播又发现，两者互不注销。
 * `stopAdvertisement()` 只停广告、`stopDiscovery()` 只停发现，`stopAll()` 才全部停止。
 *
 * TXT 记录白名单：proto / port / device / caps。禁止广播 userId 及任何派生形态、
 * 密码、token、K_lan、salt、证书指纹、文件名、明文。
 *
 * Android 13+ 无 NEARBY_WIFI_DEVICES 权限时，register/discover 会抛
 * SecurityException——插件内先查权限再注册，缺失返回 `permissionDenied` 给 Dart，
 * 由上层安全降级走 Cloud（不阻塞主流程）。
 */
class LanNetworkPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var eventChannel: EventChannel? = null
    private lateinit var context: Context
    private var nsdManager: NsdManager? = null
    private var registeredServiceInfo: NsdServiceInfo? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val serviceType = "_clipflow._tcp."

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "clipflow/lan_network")
        channel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "clipflow/lan_network_events")
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
        context = binding.applicationContext
        nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAll()
        channel.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        eventChannel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(true)
            "advertise" -> {
                val deviceId = call.argument<String>("deviceId")
                val port = call.argument<Int>("port")
                if (deviceId.isNullOrEmpty() || port == null) {
                    result.error("badArgs", "deviceId/port required", null)
                    return
                }
                if (!hasNearbyWifiPermission()) {
                    result.error("permissionDenied", "NEARBY_WIFI_DEVICES permission required", null)
                    return
                }
                val caps = call.argument<String>("caps") ?: "t"
                advertise(deviceId, caps, port, result)
            }
            "browse" -> {
                if (!hasNearbyWifiPermission()) {
                    result.error("permissionDenied", "NEARBY_WIFI_DEVICES permission required", null)
                    return
                }
                browse(result)
            }
            "stopAll" -> {
                stopAll()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** Android 13+ 需要 NEARBY_WIFI_DEVICES（usesPermissionFlags=neverForLocation）。 */
    private fun hasNearbyWifiPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return context.checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun advertise(deviceId: String, caps: String, port: Int, result: MethodChannel.Result) {
        val manager = nsdManager
        if (manager == null) {
            result.error("unsupported", "NsdManager unavailable", null)
            return
        }
        stopAdvertisement()
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = deviceId
            serviceType = this@LanNetworkPlugin.serviceType
            setPort(port)
            setAttribute("proto", "1")
            setAttribute("device", deviceId)
            setAttribute("caps", caps)
        }
        val registrationListener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                registeredServiceInfo = info
                mainHandler.post { result.success(null) }
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                mainHandler.post { result.error("registerFailed", "mDNS register failed: $errorCode", null) }
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {}

            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        this.registrationListener = registrationListener
        try {
            manager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        } catch (e: SecurityException) {
            result.error("permissionDenied", "NEARBY_WIFI_DEVICES permission required", null)
        } catch (e: Exception) {
            result.error("registerFailed", "mDNS register exception: ${e.message}", null)
        }
    }

    private fun browse(result: MethodChannel.Result) {
        val manager = nsdManager
        if (manager == null) {
            result.error("unsupported", "NsdManager unavailable", null)
            return
        }
        stopDiscovery()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                mainHandler.post { result.success(null) }
            }

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                mainHandler.post {
                    try {
                        manager.resolveService(
                            serviceInfo,
                            object : NsdManager.ResolveListener {
                                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                                    // 单个服务解析失败仅忽略，不中断发现
                                }

                                override fun onServiceResolved(info: NsdServiceInfo) {
                                    val txt = HashMap<String, String>()
                                    for ((key, value) in info.attributes) {
                                        txt[key] = String(value)
                                    }
                                    // NsdManager 回调运行在其内部 ServiceHandler 线程（ConnectivityThread），
                                    // 必须 post 到主线程后再发 EventChannel 事件（Flutter JNI 要求主线程）。
                                    mainHandler.post {
                                        eventSink?.success(
                                            mapOf(
                                                "name" to info.serviceName,
                                                "host" to (info.host?.hostAddress ?: ""),
                                                "port" to info.port,
                                                "txt" to txt
                                            )
                                        )
                                    }
                                }
                            }
                        )
                    } catch (e: Exception) {
                        // resolve 异常仅忽略
                    }
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                mainHandler.post { result.error("browseFailed", "mDNS browse failed: $errorCode", null) }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        discoveryListener = listener
        try {
            manager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (e: SecurityException) {
            result.error("permissionDenied", "NEARBY_WIFI_DEVICES permission required", null)
        } catch (e: Exception) {
            result.error("browseFailed", "mDNS browse exception: ${e.message}", null)
        }
    }

    /**
     * 仅停止广告广播：注销已注册的 mDNS 服务并置空 registeredServiceInfo，
     * 不影响正在进行的服务发现（广告与发现可共存，同进程既广播又发现）。
     */
    private fun stopAdvertisement() {
        val manager = nsdManager ?: return
        try {
            registrationListener?.let { manager.unregisterService(it) }
        } catch (_: Exception) {
        }
        registrationListener = null
        registeredServiceInfo = null
    }

    /**
     * 仅停止服务发现：停止 discovery listener 并置空 discoveryListener，
     * 不注销已注册的 mDNS 广告（广告与发现可共存，同进程既广播又发现）。
     */
    private fun stopDiscovery() {
        val manager = nsdManager ?: return
        try {
            discoveryListener?.let { manager.stopServiceDiscovery(it) }
        } catch (_: Exception) {
        }
        discoveryListener = null
    }

    /** 同时停止广告广播与服务发现（MethodChannel `stopAll` 语义：全部停止）。 */
    private fun stopAll() {
        stopAdvertisement()
        stopDiscovery()
    }
}
