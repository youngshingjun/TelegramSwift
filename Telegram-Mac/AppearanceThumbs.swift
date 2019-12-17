//
//  AppearanceThumbs.swift
//  Telegram
//
//  Created by Mikhail Filimonov on 14/09/2019.
//  Copyright © 2019 Telegram. All rights reserved.
//

import Cocoa
import TelegramCore
import SyncCore
import TGUIKit
import SwiftSignalKit
import Postbox

private func cloudThemeData(context: AccountContext, file: TelegramMediaFile) -> Signal<(ColorPalette, Wallpaper, TelegramWallpaper?), NoError> {
    return Signal { subscriber in
        
        let fetchDisposable = fetchedMediaResource(mediaBox: context.account.postbox.mediaBox, reference: MediaResourceReference.standalone(resource: file.resource)).start()
        let wallpaperDisposable = DisposableSet()
        
        let resourceData = context.account.postbox.mediaBox.resourceData(file.resource) |> filter { $0.complete } |> take(1)
        
        let dataDisposable = resourceData.start(next: { data in
            if let palette = importPalette(data.path) {
                var wallpaper: Signal<TelegramWallpaper?, GetWallpaperError> = .single(nil)
                var newSettings: WallpaperSettings = WallpaperSettings()
                switch palette.wallpaper {
                case .none:
                    wallpaper = .single(nil)
                case .builtin:
                    wallpaper = .single(.builtin(newSettings))
                case let .color(color):
                    wallpaper = .single(.color(Int32(color.rgb)))
                case let .url(string):
                    let link = inApp(for: string as NSString, context: context)
                    switch link {
                    case let .wallpaper(values):
                        switch values.preview {
                        case let .slug(slug, settings):
                            wallpaper = getWallpaper(account: context.account, slug: slug) |> map(Optional.init)
                            newSettings = settings
                        default:
                            break
                        }
                    default:
                        break
                    }
                }
                
                wallpaperDisposable.add(wallpaper.start(next: { cloud in
                    if let cloud = cloud {
                        let wp = Wallpaper(cloud).withUpdatedSettings(newSettings)
                        wallpaperDisposable.add(moveWallpaperToCache(postbox: context.account.postbox, wallpaper: wp).start(next: { wallpaper in
                            subscriber.putNext((palette, wallpaper, cloud))
                            subscriber.putCompletion()
                        }))
                    } else {
                        subscriber.putNext((palette, .none, nil))
                        subscriber.putCompletion()
                    }
                }, error: { _ in
                    subscriber.putCompletion()
                }))
            }
            
        })

        return ActionDisposable {
            fetchDisposable.dispose()
            dataDisposable.dispose()
            wallpaperDisposable.dispose()
        }
    }
}



private func generateThumb(palette: ColorPalette, bubbled: Bool, wallpaper: Wallpaper) -> Signal<CGImage, NoError> {
    return Signal { subscriber in
        let image = generateImage(NSMakeSize(80, 55), rotatedContext: { size, ctx in
            let rect = NSMakeRect(0, 0, size.width, size.height)
            ctx.clear(rect)
            ctx.round(size, 10)
            
            
            let backgroundMode: TableBackgroundMode
            if bubbled {
                switch wallpaper {
                case .builtin:
                    backgroundMode = .background(image: #imageLiteral(resourceName: "builtin-wallpaper-0.jpg"))
                case let.color(color):
                    backgroundMode = .color(color: NSColor(UInt32(abs(color))))
                case let .gradient(top, bottom):
                    backgroundMode = .gradient(top: NSColor(UInt32(abs(top))), bottom: NSColor(UInt32(abs(bottom))))
                case let .image(representation, settings):
                    if let resource = largestImageRepresentation(representation)?.resource, let image = NSImage(contentsOf: URL(fileURLWithPath: wallpaperPath(resource, blurred: settings.blur))) {
                        backgroundMode = .background(image: image)
                    } else {
                        backgroundMode = .background(image: #imageLiteral(resourceName: "builtin-wallpaper-0.jpg"))
                    }
                    
                case let .file(_, file, settings, isPattern):
                    if let image = NSImage(contentsOf: URL(fileURLWithPath: wallpaperPath(file.resource, blurred: settings.blur))) {
                        if isPattern {
                            let image = generateImage(image.size, contextGenerator: { size, ctx in
                                let imageRect = NSMakeRect(0, 0, size.width, size.height)
                                let colors:[NSColor]
                                let color: NSColor
                                var intensity: CGFloat = 0.5
                                
                                if let combinedColor = settings.color, settings.bottomColor == nil {
                                    let combinedColor = NSColor(UInt32(combinedColor))
                                    if let i = settings.intensity {
                                        intensity = CGFloat(i) / 100.0
                                    }
                                    color = combinedColor.withAlphaComponent(1.0)
                                    intensity = combinedColor.alpha
                                    colors = [color]
                                } else if let t = settings.color, let b = settings.bottomColor {
                                    let top = NSColor(UInt32(t))
                                    let bottom = NSColor(UInt32(b))
                                    color = top.withAlphaComponent(1.0)
                                    intensity = top.alpha
                                    colors = [top, bottom].reversed().map { $0.withAlphaComponent(1.0) }
                                } else {
                                    colors = [NSColor(rgb: 0xd6e2ee, alpha: 0.5)]
                                    color = NSColor(rgb: 0xd6e2ee, alpha: 0.5)
                                }
                                
                                ctx.setBlendMode(.copy)
                                if colors.count == 1 {
                                    ctx.setFillColor(color.cgColor)
                                    ctx.fill(imageRect)
                                } else {
                                    let gradientColors = colors.map { $0.cgColor } as CFArray
                                    let delta: CGFloat = 1.0 / (CGFloat(colors.count) - 1.0)
                                    
                                    var locations: [CGFloat] = []
                                    for i in 0 ..< colors.count {
                                        locations.append(delta * CGFloat(i))
                                    }
                                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                                    let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: &locations)!
                                    
                                    ctx.saveGState()
                                    ctx.translateBy(x: imageRect.width / 2.0, y: imageRect.height / 2.0)
                                    ctx.rotate(by: CGFloat(0) * CGFloat.pi / -180.0)
                                    ctx.translateBy(x: -imageRect.width / 2.0, y: -imageRect.height / 2.0)
                                    
                                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: imageRect.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                                    ctx.restoreGState()
                                }
                                
                                ctx.setBlendMode(.normal)
                                ctx.interpolationQuality = .high
                                
                                ctx.clip(to: imageRect, mask: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
                                ctx.setFillColor(patternColor(for: color, intensity: intensity).cgColor)
                                ctx.fill(imageRect)
                            })!
                            backgroundMode = .background(image: NSImage(cgImage: image, size: image.size))
                        } else {
                            backgroundMode = .background(image: image)
                        }
                    } else {
                        backgroundMode = .background(image: #imageLiteral(resourceName: "builtin-wallpaper-0.jpg"))
                    }
                case .none:
                    backgroundMode = .color(color: palette.chatBackground)
                case let .custom(representation, blurred):
                    if let image = NSImage(contentsOf: URL(fileURLWithPath: wallpaperPath(representation.resource, blurred: blurred))) {
                        backgroundMode = .background(image: image)
                    } else {
                        backgroundMode = .background(image: #imageLiteral(resourceName: "builtin-wallpaper-0.jpg"))
                    }
                }
            } else {
                backgroundMode = .color(color: palette.chatBackground)
            }
            
            func applyBubbles() {
                let bubbleImage = NSImage(named: "Icon_ThemeBubble")
                if let outgoing = bubbleImage?.precomposed(palette.bubbleBackground_incoming, flipVertical: true) {
                    ctx.draw(outgoing, in: NSMakeRect(7, 9, 48, 16))
                }
                if let incoming = bubbleImage?.precomposed(palette.bubbleBackground_outgoing, flipVertical: true, flipHorizontal: true) {
                    ctx.draw(incoming, in: NSMakeRect(size.width - 57, size.height - 24, 48, 16))
                }
            }
            
            func applyPlain() {
                ctx.setFillColor(palette.accent.cgColor)
                ctx.fillEllipse(in: NSMakeRect(10, 7, 17, 17))
                
                if true {
                    let name1 = generateImage(NSMakeSize(20, 4), rotatedContext: { size, ctx in
                        let rect = NSMakeRect(0, 0, size.width, size.height)
                        ctx.clear(rect)
                        ctx.round(size, 2)
                        ctx.setFillColor(palette.accent.cgColor)
                        ctx.fill(rect)
                    })!
                    ctx.draw(name1, in: NSMakeRect(10 + 17 + 3, 7 + 2, name1.backingSize.width, name1.backingSize.height))
                    
                    let text1 = generateImage(NSMakeSize(40, 4), rotatedContext: { size, ctx in
                        let rect = NSMakeRect(0, 0, size.width, size.height)
                        ctx.clear(rect)
                        ctx.round(size, 2)
                        ctx.setFillColor(palette.grayText.cgColor)
                        ctx.fill(rect)
                    })!
                    ctx.draw(text1, in: NSMakeRect(10 + 17 + 3, 7 + 2 + 4 + 4, text1.backingSize.width, text1.backingSize.height))
                }
                
                if true {
                    ctx.setFillColor(palette.accent.cgColor)
                    ctx.fillEllipse(in: NSMakeRect(10, 7 + 17 + 7, 17, 17))
                    
                    let name1 = generateImage(NSMakeSize(20, 4), rotatedContext: { size, ctx in
                        let rect = NSMakeRect(0, 0, size.width, size.height)
                        ctx.clear(rect)
                        ctx.round(size, 2)
                        ctx.setFillColor(palette.accent.cgColor)
                        ctx.fill(rect)
                    })!
                    ctx.draw(name1, in: NSMakeRect(10 + 17 + 3, 7 + 17 + 7 + 2, name1.backingSize.width, name1.backingSize.height))
                    
                    let text1 = generateImage(NSMakeSize(40, 4), rotatedContext: { size, ctx in
                        let rect = NSMakeRect(0, 0, size.width, size.height)
                        ctx.clear(rect)
                        ctx.round(size, 2)
                        ctx.setFillColor(palette.grayText.cgColor)
                        ctx.fill(rect)
                    })!
                    ctx.draw(text1, in: NSMakeRect(10 + 17 + 3, 7 + 17 + 7 + 2 + 4 + 4, text1.backingSize.width, text1.backingSize.height))
                }
                
                
            }
            
            switch backgroundMode {
            case let .background(image):
                let imageSize = image.size.aspectFilled(size)
                ctx.draw(image.precomposed(flipVertical: true), in: rect.focus(imageSize))
                applyBubbles()
            case let .color(color):
                if bubbled {
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(rect)
                    applyBubbles()
                } else {
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(rect)
                    applyPlain()
                }
                
            default:
                break
            }
            
        })!
        
        subscriber.putNext(image)
        subscriber.putCompletion()
        
        return EmptyDisposable
    } |> runOn(Queue.concurrentDefaultQueue())
}

func themeAppearanceThumbAndData(context: AccountContext, bubbled: Bool, source: ThemeSource) -> Signal<(TransformImageResult, InstallThemeSource), NoError> {
    
    switch source {
    case let .cloud(cloud):
        if let file = cloud.file {
            return cloudThemeData(context: context, file: file) |> mapToSignal { data in
                return generateThumb(palette: data.0, bubbled: bubbled, wallpaper: data.1) |> map { image in
                    return (TransformImageResult(image, true), .cloud(cloud, InstallCloudThemeCachedData(palette: data.0, wallpaper: data.1, cloudWallpaper: data.2)))
                }
            }
        } else {
            return .single((TransformImageResult(theme.icons.appearanceAddPlatformTheme, true), .cloud(cloud, nil)))
        }
    case let .local(palette):
        return generateThumb(palette: palette, bubbled: bubbled, wallpaper: palette.name == dayClassicPalette.name ? .builtin : .none) |> map { image in
            return (TransformImageResult(image, true), .local(palette))
        }
    }
}


