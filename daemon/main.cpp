// screen-dimmer: keeps KWin's per-output software dimming at the level chosen in the widget.
//
// KWin applies `dimming` in its color pipeline (never sent over DDC/CI), but powerdevil rewrites it
// on every brightness change and on idle dim/undim. This daemon watches the outputs through
// libkscreen and puts the user's level back, multiplied by whatever factor powerdevil asked for
// (1.0 normally, 0.3 while dimmed for inactivity). It only reacts to events: no timers, no polling.
//
// Files in $XDG_RUNTIME_DIR/screen-dimmer/ (tmpfs: everything is back to 100% after a reboot):
//   levels  written by the widget, one "<connector> <0-100>" per line
//   state   written here, one "<connector>\t<label>\t<level>\t<dimming 0-100>\t<priority>" per line

#include <KScreen/Config>
#include <KScreen/ConfigMonitor>
#include <KScreen/EDID>
#include <KScreen/GetConfigOperation>
#include <KScreen/Output>
#include <KScreen/SetConfigOperation>

#include <QGuiApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileSystemWatcher>
#include <QHash>
#include <QSaveFile>
#include <QSocketNotifier>
#include <QTimer>

#include <functional>

#include <sys/signalfd.h>
#include <csignal>
#include <unistd.h>

using namespace Qt::StringLiterals;

namespace
{
constexpr double Epsilon = 0.005;   // dimming travels as an integer 0-10000 on the wire
constexpr int MaxWritesPerWindow = 10;
constexpr qint64 WindowMs = 5000;

struct OutputState {
    double level = 1.0;           // chosen in the widget
    double factor = 1.0;          // last value set by someone else (powerdevil)
    double written = -1.0;        // last value we sent, to recognise our own change notifications
    qint64 windowStart = 0;
    int writesInWindow = 0;
    bool warned = false;
};

class Dimmer : public QObject
{
public:
    explicit Dimmer(const QString &dir)
        : m_dir(dir)
    {
        QDir().mkpath(m_dir);
        m_watcher.addPath(m_dir);
        connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &Dimmer::readLevels);

        auto *op = new KScreen::GetConfigOperation();
        connect(op, &KScreen::ConfigOperation::finished, this, [this, op] {
            if (op->hasError()) {
                qCritical("Cannot read the output configuration: %s", qPrintable(op->errorString()));
                QCoreApplication::exit(1);
                return;
            }
            m_config = op->config();
            KScreen::ConfigMonitor::instance()->addConfig(m_config);
            connect(m_config.data(), &KScreen::Config::outputAdded, this, [this](const KScreen::OutputPtr &o) {
                watch(o);
                sync();
            });
            connect(m_config.data(), &KScreen::Config::outputRemoved, this, [this] { writeState(); });
            for (const auto &o : m_config->outputs()) {
                watch(o);
            }
            readLevels();
        });
    }

    // Back to 100% on exit, so stopping the service never leaves a screen dark.
    // Runs inside the event loop: the request must reach KWin before the process ends.
    void restore(const std::function<void()> &done)
    {
        m_stopping = true;
        QFile::remove(m_dir + "/state"_L1);
        bool changed = false;
        if (m_config) {
            for (const auto &o : m_config->outputs()) {
                if (o->dimming() < 1.0 - Epsilon) {
                    o->setDimming(1.0);
                    changed = true;
                }
            }
        }
        if (!changed) {
            done();
            return;
        }
        auto *op = new KScreen::SetConfigOperation(m_config);
        connect(op, &KScreen::ConfigOperation::finished, this, done);
    }

private:
    void watch(const KScreen::OutputPtr &o)
    {
        const int id = o->id();
        connect(o.data(), &KScreen::Output::dimmingChanged, this, [this, id] { onDimmingChanged(id); });
        connect(o.data(), &KScreen::Output::isConnectedChanged, this, &Dimmer::sync);
        connect(o.data(), &KScreen::Output::isEnabledChanged, this, &Dimmer::sync);
    }

    static bool active(const KScreen::OutputPtr &o)
    {
        return o->isConnected() && o->isEnabled();
    }

    void readLevels()
    {
        QHash<QString, double> levels;
        QFile f(m_dir + "/levels"_L1);
        if (f.open(QIODevice::ReadOnly)) {
            for (const QByteArray &line : f.readAll().split('\n')) {
                const QList<QByteArray> p = line.simplified().split(' ');
                bool ok = false;
                const int v = p.size() == 2 ? p[1].toInt(&ok) : 0;
                if (ok) {
                    levels.insert(QString::fromUtf8(p[0]), std::clamp(v, 0, 100) / 100.0);
                }
            }
        }
        for (auto it = m_state.begin(); it != m_state.end(); ++it) {
            it->level = levels.value(it.key(), 1.0);
        }
        for (auto it = levels.cbegin(); it != levels.cend(); ++it) {
            m_state[it.key()].level = it.value();
        }
        sync();
    }

    // Someone changed the dimming of an output: either us (ignore) or powerdevil (remember its factor).
    void onDimmingChanged(int id)
    {
        const auto o = m_config->output(id);
        if (!o || !active(o)) {
            return;
        }
        OutputState &s = m_state[o->name()];
        if (std::abs(o->dimming() - s.written) > Epsilon) {
            s.factor = o->dimming();
            s.written = -1.0;
        }
        sync();
    }

    void sync()
    {
        if (!m_config || m_stopping) {
            return;
        }
        bool changed = false;
        const qint64 now = QDateTime::currentMSecsSinceEpoch();
        for (const auto &o : m_config->outputs()) {
            if (!active(o)) {
                continue;
            }
            OutputState &s = m_state[o->name()];
            const double target = s.level * s.factor;
            if (std::abs(o->dimming() - target) <= Epsilon) {
                continue;
            }
            // Guard against a tug of war with another program rewriting the value
            if (now - s.windowStart > WindowMs) {
                s.windowStart = now;
                s.writesInWindow = 0;
                s.warned = false;
            }
            if (++s.writesInWindow > MaxWritesPerWindow) {
                if (!s.warned) {
                    qWarning("%s: dimming keeps being changed by another program, pausing for a few seconds",
                             qPrintable(o->name()));
                    s.warned = true;
                }
                continue;
            }
            s.written = target;
            o->setDimming(target);
            changed = true;
        }
        if (changed) {
            new KScreen::SetConfigOperation(m_config);   // deletes itself when finished
        }
        writeState();
    }

    void writeState()
    {
        QByteArray out;
        for (const auto &o : m_config->outputs()) {
            if (!active(o)) {
                continue;
            }
            QString label = o->edid() ? o->edid()->name() : QString();
            if (label.isEmpty()) {
                label = o->name();
            }
            const OutputState &s = m_state[o->name()];
            out += u"%1\t%2\t%3\t%4\t%5\n"_s.arg(o->name(), label.simplified())
                       .arg(qRound(s.level * 100))
                       .arg(qRound(o->dimming() * 100))
                       .arg(o->priority())
                       .toUtf8();
        }
        if (out == m_lastState) {
            return;
        }
        QSaveFile f(m_dir + "/state"_L1);
        if (f.open(QIODevice::WriteOnly) && f.write(out) == out.size() && f.commit()) {
            m_lastState = out;
        }
    }

    QString m_dir;
    QFileSystemWatcher m_watcher;
    KScreen::ConfigPtr m_config;
    QHash<QString, OutputState> m_state;   // by connector name (DP-1, ...)
    QByteArray m_lastState;
    bool m_stopping = false;
};
} // namespace

int main(int argc, char **argv)
{
    // SIGTERM/SIGINT arrive through a signalfd, so cleanup runs in the event loop
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGTERM);
    sigaddset(&mask, SIGINT);
    sigprocmask(SIG_BLOCK, &mask, nullptr);
    const int sfd = signalfd(-1, &mask, SFD_CLOEXEC);

    QGuiApplication app(argc, argv);   // libkscreen's Wayland backend needs the GUI connection
    const QByteArray runtime = qgetenv("XDG_RUNTIME_DIR");
    if (runtime.isEmpty()) {
        qCritical("XDG_RUNTIME_DIR is not set");
        return 1;
    }
    Dimmer dimmer(QString::fromLocal8Bit(runtime) + "/screen-dimmer"_L1);

    QSocketNotifier notifier(sfd, QSocketNotifier::Read);
    QObject::connect(&notifier, &QSocketNotifier::activated, &app, [sfd, &notifier, &dimmer] {
        signalfd_siginfo info;
        if (read(sfd, &info, sizeof(info)) <= 0) {
            return;
        }
        notifier.setEnabled(false);
        dimmer.restore([] { QCoreApplication::quit(); });
        QTimer::singleShot(3000, &QCoreApplication::quit);   // never hang on shutdown
    });

    return app.exec();
}
