// A normal Qt application fixture: real mixed text/HTML/image clipboard formats.
#include <QtGui>
int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    auto *data = new QMimeData;
    const QString text = QString::fromUtf8("原生 mixed 文本 😀");
    data->setText(text);
    data->setHtml("<b>" + text + "</b>");
    QImage image(2, 2, QImage::Format_ARGB32);
    image.fill(Qt::red);
    data->setImageData(image);
    app.clipboard()->setMimeData(data);
    return app.exec();
}
