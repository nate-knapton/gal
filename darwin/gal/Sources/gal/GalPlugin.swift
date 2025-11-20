import Photos

#if os(iOS)
import Flutter
import UIKit
#else
import Cocoa
import FlutterMacOS
#endif

public class GalPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif

    let channel = FlutterMethodChannel(name: "gal", binaryMessenger: messenger)
    let instance = GalPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "putVideo", "putImage":
      let args = call.arguments as! [String: Any]
      putMedia(
        path: args["path"] as! String,
        album: args["album"] as? String,
        isImage: call.method == "putImage"
      ) { _, error in
        result(error == nil ? nil : self.handleError(error: error!))
      }

    case "putImageBytes", "putVideoBytes":
      let args = call.arguments as! [String: Any]
      putMediaBytes(
        bytes: (args["bytes"] as! FlutterStandardTypedData).data,
        album: args["album"] as? String,
        name: args["name"] as! String,
        isImage: call.method == "putImageBytes"
      ) { _, error in
        result(error == nil ? nil : self.handleError(error: error!))
      }

    case "open":
      open { result(nil) }

    case "hasAccess":
      let args = call.arguments as! [String: Bool]
      result(hasAccess(toAlbum: args["toAlbum"]!))

    case "requestAccess":
      let args = call.arguments as! [String: Bool]
      let toAlbum = args["toAlbum"]!
      hasAccess(toAlbum: toAlbum)
        ? result(true)
        : requestAccess(toAlbum: toAlbum) { granted in result(granted) }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func putMedia(
    path: String, album: String?, isImage: Bool,
    completion: @escaping (Bool, Error?) -> Void
  ) {
    let url = URL(fileURLWithPath: path)

    writeContent(
      assetChangeRequest: {
        let req: PHAssetChangeRequest =
          isImage
            ? PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)!
            : PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)!

        req.creationDate = Date()
        return req
      },
      album: album,
      completion: completion
    )
  }

  private func putMediaBytes(
    bytes: Data, album: String?, name: String,
    isImage: Bool,
    completion: @escaping (Bool, Error?) -> Void
  ) {
    writeContent(
      assetChangeRequest: {
        let request = PHAssetCreationRequest.forAsset()
        request.creationDate = Date()

        let options = PHAssetResourceCreationOptions()
        options.originalFilename = name

        let resourceType: PHAssetResourceType = isImage ? .photo : .video

        request.addResource(with: resourceType, data: bytes, options: options)
        return request
      },
      album: album,
      completion: completion
    )
  }

  private func writeContent(
    assetChangeRequest: @escaping () -> PHAssetChangeRequest,
    album: String?,
    completion: @escaping (Bool, Error?) -> Void
  ) {
    if let album = album {
      getAlbum(album: album) { collection, error in
        if let error = error {
          completion(false, error)
          return
        }

        PHPhotoLibrary.shared().performChanges({
          let assetReq = assetChangeRequest()
          let placeholder = assetReq.placeholderForCreatedAsset!

          let albumChangeRequest = PHAssetCollectionChangeRequest(for: collection!)
          albumChangeRequest!.addAssets([placeholder] as NSArray)
        }, completionHandler: completion)
      }
      return
    }

    PHPhotoLibrary.shared().performChanges({
      _ = assetChangeRequest()
    }, completionHandler: completion)
  }

  private func getAlbum(album: String, completion: @escaping (PHAssetCollection?, Error?) -> Void) {
    let fetchOptions = PHFetchOptions()
    fetchOptions.predicate = NSPredicate(format: "title = %@", album)

    let collections = PHAssetCollection.fetchAssetCollections(
      with: .album,
      subtype: .any,
      options: fetchOptions
    )

    if let collection = collections.firstObject {
      completion(collection, nil)
      return
    }

    PHPhotoLibrary.shared().performChanges({
      PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
    }, completionHandler: { success, error in
      success
        ? self.getAlbum(album: album, completion: completion)
        : completion(nil, error)
    })
  }

  private func open(completion: @escaping () -> Void) {
    #if os(iOS)
    guard let url = URL(string: "photos-redirect://") else { return }
    UIApplication.shared.open(url, options: [:]) { _ in completion() }
    #else
    guard let url = URL(string: "photos://") else { return }
    NSWorkspace.shared.open(url)
    completion()
    #endif
  }

  private func hasAccess(toAlbum: Bool) -> Bool {
    if #available(iOS 14, macOS 11, *) {
      return toAlbum
        ? PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized ||
          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
        : PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized
    }
    return PHPhotoLibrary.authorizationStatus() == .authorized
  }

  private func requestAccess(toAlbum: Bool, completion: @escaping (Bool) -> Void) {
    if #available(iOS 14, macOS 11, *) {
      PHPhotoLibrary.requestAuthorization(for: toAlbum ? .readWrite : .addOnly) { _ in
        completion(self.hasAccess(toAlbum: toAlbum))
      }
    } else {
      PHPhotoLibrary.requestAuthorization { _ in
        completion(PHPhotoLibrary.authorizationStatus() == .authorized)
      }
    }
  }

  private func handleError(error: Error) -> FlutterError {
    let error = error as NSError
    let message = error.localizedDescription
    let details = Thread.callStackSymbols

    switch PHErrorCode(rawValue: error.code) {
    case .accessRestricted, .accessUserDenied:
      return FlutterError(code: "ACCESS_DENIED", message: message, details: details)
    case .identifierNotFound, .multipleIdentifiersFound,
         .requestNotSupportedForAsset, .videoConversionFailed, .unsupportedVideoCodec:
      return FlutterError(code: "NOT_SUPPORTED_FORMAT", message: message, details: details)
    case .notEnoughSpace:
      return FlutterError(code: "NOT_ENOUGH_SPACE", message: message, details: details)
    default:
      return FlutterError(code: "UNEXPECTED", message: message, details: details)
    }
  }
}

enum PHErrorCode: Int {
  case identifierNotFound = 3201
  case multipleIdentifiersFound = 3202
  case videoConversionFailed = 3300
  case unsupportedVideoCodec = 3302
  case notEnoughSpace = 3305
  case requestNotSupportedForAsset = 3306
  case accessRestricted = 3310
  case accessUserDenied = 3311
}
