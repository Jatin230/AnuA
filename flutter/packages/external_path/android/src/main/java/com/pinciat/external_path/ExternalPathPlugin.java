package com.pinciat.external_path;

import android.content.Context;
import android.os.Environment;

import java.io.File;
import java.util.ArrayList;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

public class ExternalPathPlugin implements FlutterPlugin, MethodCallHandler {
  private MethodChannel channel;
  private Context context;

  @Override
  public void onAttachedToEngine(FlutterPlugin.FlutterPluginBinding flutterPluginBinding) {
    context = flutterPluginBinding.getApplicationContext();
    channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "external_path");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(MethodCall call, Result result) {
    if ("getExternalStorageDirectories".equals(call.method)) {
      result.success(getExternalStorageDirectories());
    } else if ("getExternalStoragePublicDirectory".equals(call.method)) {
      result.success(getExternalStoragePublicDirectory(call.argument("type")));
    } else {
      result.notImplemented();
    }
  }

  private ArrayList<String> getExternalStorageDirectories() {
    File[] appsDir = context.getExternalFilesDirs(null);
    ArrayList<String> extRootPaths = new ArrayList<>();
    for (File file : appsDir) {
      extRootPaths.add(file.getAbsolutePath());
    }
    return extRootPaths;
  }

  private String getExternalStoragePublicDirectory(String type) {
    return Environment.getExternalStoragePublicDirectory(type).toString();
  }

  @Override
  public void onDetachedFromEngine(FlutterPlugin.FlutterPluginBinding binding) {
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
  }
}
