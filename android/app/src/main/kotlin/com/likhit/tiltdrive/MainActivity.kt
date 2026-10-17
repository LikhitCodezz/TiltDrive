package com.likhit.tiltdrive

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI

class MainActivity : FlutterActivity(), SensorEventListener {
    private lateinit var sensorManager: SensorManager
    private var rotationSensor: Sensor? = null
    private var accelerometer: Sensor? = null
    private var gyroscope: Sensor? = null
    private var eventSink: EventChannel.EventSink? = null
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)
    private var lastAcceleration = 9.8
    private var lastGyroMagnitude = 0.0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        rotationSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
        accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyroscope = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tiltdrive/sensors")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val rotation = rotationSensor
                        if (rotation == null) {
                            result.success(mapOf("rotation" to false, "accelerometer" to (accelerometer != null)))
                        } else {
                            sensorManager.registerListener(this, rotation, SensorManager.SENSOR_DELAY_GAME)
                            accelerometer?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
                            gyroscope?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
                            result.success(mapOf("rotation" to true, "accelerometer" to (accelerometer != null), "gyroscope" to (gyroscope != null)))
                        }
                    }
                    "stop" -> {
                        sensorManager.unregisterListener(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "tiltdrive/sensor_events")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    eventSink = sink
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                    sensorManager.unregisterListener(this@MainActivity)
                }
            })
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
                SensorManager.getOrientation(rotationMatrix, orientation)
                val roll = orientation[2] * 180.0 / PI
                val pitch = orientation[1] * 180.0 / PI
                eventSink?.success(mapOf("roll" to roll, "pitch" to pitch, "accel" to lastAcceleration, "gyro" to lastGyroMagnitude))
            }
            Sensor.TYPE_ACCELEROMETER -> {
                val x = event.values[0].toDouble()
                val y = event.values[1].toDouble()
                val z = event.values[2].toDouble()
                lastAcceleration = kotlin.math.sqrt(x * x + y * y + z * z)
            }
            Sensor.TYPE_GYROSCOPE -> {
                val x = event.values[0].toDouble()
                val y = event.values[1].toDouble()
                val z = event.values[2].toDouble()
                lastGyroMagnitude = kotlin.math.sqrt(x * x + y * y + z * z)
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onResume() {
        super.onResume()
        if (eventSink != null) {
            rotationSensor?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
            accelerometer?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
            gyroscope?.let { sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        }
    }

    override fun onPause() {
        super.onPause()
        sensorManager.unregisterListener(this)
    }
}
