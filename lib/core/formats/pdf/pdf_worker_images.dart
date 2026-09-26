import 'package:pdf_cos/pdf_cos.dart';
import 'package:pdf_graphics/pdf_graphics.dart';

/// Worker buffers use references instead of duplicating image stream graphs.
/// Rebind those references before the Canvas adapter keys its decoded images
/// by stream identity; otherwise distinct XObjects share the placeholder key.
List<PdfRenderCommand> bindPdfWorkerImages(
  List<PdfRenderCommand> commands,
  CosDocument document,
) => commands
    .map((command) {
      switch (command) {
        case PdfDrawImageCommand(:final request):
          final reference = request.sourceReference;
          if (reference == null) return command;
          final stream = document.resolve(reference);
          if (stream is! CosStream) {
            throw const FormatException(
              'PDF worker image reference is missing',
            );
          }
          return PdfDrawImageCommand(
            PdfImageRequest(
              stream: stream,
              transform: request.transform,
              alpha: request.alpha,
              isStencil: request.isStencil,
              stencilColor: request.stencilColor,
              isInline: request.isInline,
              decoded: request.decoded,
              sourceReference: reference,
            ),
          );
        case PdfEndSoftMaskedCommand():
          return PdfEndSoftMaskedCommand(
            luminosity: command.luminosity,
            backdrop: command.backdrop,
            maskCommands: bindPdfWorkerImages(command.maskCommands, document),
            backdropLuminance: command.backdropLuminance,
            transferScale: command.transferScale,
            transferOffset: command.transferOffset,
          );
        case PdfDrawTiledCellCommand():
          return PdfDrawTiledCellCommand(
            bindPdfWorkerImages(command.cellCommands, document),
            command.originsX,
            command.originsY,
          );
        default:
          return command;
      }
    })
    .toList(growable: false);
