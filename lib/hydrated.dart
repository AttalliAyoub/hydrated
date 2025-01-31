library hydrated;

import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rxdart/rxdart.dart';
import 'package:rxdart/src/transformers/start_with.dart';
import 'package:rxdart/src/transformers/start_with_error.dart';

/// A [Subject] that automatically persists its values and hydrates on creation.
///
/// HydratedSubject supports serialized classes and [shared_preferences] types such as: `int`, `double`, `bool`, `String`, and `List<String>`
///
/// Serialized classes are supported by using the `hydrate: (String)=>Class` and `persist: (Class)=>String` constructor arguments.
///
/// Example:
///
/// ```
///   final count$ = HydratedSubject<int>("count", seedValue: 0);
/// ```
///
/// Serialized class example:
///
/// ```
///   final user$ = HydratedSubject<User>(
///     "user",
///     hydrate: (String s) => User.fromJSON(s),
///     persist: (User user) => user.toJSON(),
///     seedValue: User.empty(),
///   );
/// ```
///
/// Hydration is performed automatically and is asynchronous. The `onHydrate` callback is called when hydration is complete.
///
/// ```
///   final user$ = HydratedSubject<int>(
///     "count",
///     onHydrate: () => loading$.add(false),
///   );
/// ```

class HydratedSubject<T> extends Subject<T> implements ValueStream<T> {
  String _key;
  T _seedValue;
  _Wrapper<T> _wrapper;

  T Function(String value) _hydrate;
  String Function(T value) _persist;
  void Function() _onHydrate;

  HydratedSubject._(
    this._key,
    this._seedValue,
    this._hydrate,
    this._persist,
    this._onHydrate,
    StreamController<T> controller,
    Stream<T> observable,
    this._wrapper,
  ) : super(controller, observable) {
    _hydrateSubject();
  }

  factory HydratedSubject(
    String key, {
    T seedValue,
    T Function(String value) hydrate,
    String Function(T value) persist,
    void onHydrate(),
    void onListen(),
    void onCancel(),
    bool sync: false,
  }) {
    // assert that T is a type compatible with shared_preferences,
    // or that we have hydrate and persist mapping functions
    assert(T == int ||
        T == double ||
        T == bool ||
        T == String ||
        [""] is T ||
        (hydrate != null && persist != null));

    // ignore: close_sinks
    final controller = new StreamController<T>.broadcast(
      onListen: onListen,
      onCancel: onCancel,
      sync: sync,
    );

    final wrapper = new _Wrapper<T>.seeded(seedValue);

    return new HydratedSubject<T>._(
        key,
        seedValue,
        hydrate,
        persist,
        onHydrate,
        controller,
        Rx.defer<T>(_deferStream(wrapper, controller, sync)),
        wrapper);
  }

  static Stream<T> Function() _deferStream<T>(
          _Wrapper<T> wrapper, StreamController<T> controller, bool sync) =>
      () {
        if (wrapper.latestIsError) {
          final errorAndStackTrace = wrapper.latestErrorAndStackTrace;

          return controller.stream.transform(
            StartWithErrorStreamTransformer(
                errorAndStackTrace.error, errorAndStackTrace.stackTrace),
          );
        } else if (wrapper.latestIsValue) {
          return controller.stream
              .transform(StartWithStreamTransformer(wrapper.latestValue));
        }
        return controller.stream;
      };

  @override
  void onAddError(Object error, [StackTrace stackTrace]) =>
      _wrapper.setError(error, stackTrace);

  @override
  ValueStream<T> handleError(Function onError,
          {bool Function(Object error) test}) =>
      _forwardBehaviorSubject<T>((s) => s.handleError(onError, test: test));

  ValueStream<R> _forwardBehaviorSubject<R>(
      Stream<R> Function(Stream<T> s) transformerStream) {
    ArgumentError.checkNotNull(transformerStream, 'transformerStream');

    BehaviorSubject<R> subject;
    StreamSubscription<R> subscription;

    final onListen = () => subscription = transformerStream(this).listen(
          subject.add,
          onError: subject.addError,
          onDone: subject.close,
        );

    final onCancel = () => subscription.cancel();
    subject = createForwardingSubject(
      onListen: onListen,
      onCancel: onCancel,
      sync: true,
    );
    return subject;
  }

  @override
  void onAdd(T event) {
    _wrapper.latestValue = event;
    _persistValue(event);
  }

  @override
  ValueStream<T> get stream => this;

  /// Get the latest value emitted by the Subject
  @override
  T get value => _wrapper.latestValue;

  /// Set and emit the new value
  set value(T newValue) => add(newValue);

  @override
  bool get hasValue => _wrapper.latestValue != null;

  /// Hydrates the HydratedSubject with a value stored on the user's device.
  ///
  /// Must be called to retreive values stored on the device.
  Future<void> _hydrateSubject() async {
    final prefs = await SharedPreferences.getInstance();

    var val;

    if (this._hydrate != null)
      val = this._hydrate(prefs.getString(this._key));
    else if (T == int)
      val = prefs.getInt(this._key);
    else if (T == double)
      val = prefs.getDouble(this._key);
    else if (T == bool)
      val = prefs.getBool(this._key);
    else if (T == String)
      val = prefs.getString(this._key);
    else if ([""] is T)
      val = prefs.getStringList(this._key);
    else
      Exception(
        "HydratedSubject – shared_preferences returned an invalid type",
      );

    // do not hydrate if the store is empty or matches the seed value
    // TODO: allow writing of seedValue if it is intentional
    if (val != null && val != _seedValue) {
      add(val);
    }

    if (_onHydrate != null) {
      this._onHydrate();
    }
  }

  _persistValue(T val) async {
    final prefs = await SharedPreferences.getInstance();

    if (val is int)
      await prefs.setInt(_key, val);
    else if (val is double)
      await prefs.setDouble(_key, val);
    else if (val is bool)
      await prefs.setBool(_key, val);
    else if (val is String)
      await prefs.setString(_key, val);
    else if (val is List<String>)
      await prefs.setStringList(_key, val);
    else if (this._persist != null)
      await prefs.setString(_key, this._persist(val));
    else
      Exception(
        "HydratedSubject – value must be int, double, bool, String, or List<String>",
      );
  }

  /// A unique key that references a storage container for a value persisted on the device.
  String get key => this._key;

  @override
  Subject<R> createForwardingSubject<R>(
      {void Function() onListen, void Function() onCancel, bool sync = false}) {
    return HydratedSubject(
      key,
      onListen: onListen,
      onCancel: onCancel,
      onHydrate: _onHydrate,
      sync: sync,
    );
  }

  @override
  ErrorAndStackTrace get errorAndStackTrace =>
      _wrapper.latestErrorAndStackTrace;

  @override
  bool get hasError => _wrapper.latestIsError;
}

class _Wrapper<T> {
  T latestValue;
  ErrorAndStackTrace latestErrorAndStackTrace;

  bool latestIsValue = false, latestIsError = false;

  /// Non-seeded constructor
  _Wrapper();

  _Wrapper.seeded(this.latestValue) : latestIsValue = true;

  void setValue(T event) {
    latestIsValue = true;
    latestIsError = false;

    latestValue = event;

    latestErrorAndStackTrace = null;
  }

  void setError(Object error, [StackTrace stackTrace]) {
    latestIsValue = false;
    latestIsError = true;

    latestValue = null;

    latestErrorAndStackTrace = ErrorAndStackTrace(error, stackTrace);
  }
}
