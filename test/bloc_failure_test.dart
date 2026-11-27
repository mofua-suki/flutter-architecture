import "dart:async";

import "package:bloc_test/bloc_test.dart";
import "package:flutter_architecture/application/counter/command/increment_counter_use_case.dart";
import "package:flutter_architecture/application/counter/query/fetch_counter_use_case.dart";
import "package:flutter_architecture/application/use_case.dart";
import "package:flutter_architecture/common/logger/noop_logger.dart";
import "package:flutter_architecture/domain/counter/counter.dart";
import "package:flutter_architecture/presentation/bloc/counter/counter_bloc.dart";
import "package:flutter_architecture/presentation/bloc/share/bloc/bloc.dart" as core;
import "package:mocktail/mocktail.dart";
import "package:test/test.dart";

class _Subscriber extends Mock implements core.DomainEventSubscriber {}

class _ThrowingLogger extends NoopLogger {
  final errors = <Object?>[];
  @override
  void error({String? message, Object? error, StackTrace? stackTrace, core.Context? context}) {
    errors.add(error);
    throw StateError("log");
  }
}

class _Fetch implements FetchCounterInputPort {
  final failure = Exception("read");
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<void> perform(FetchCounterInputPortParameter parameter, OutputPort<Counter> output) async {
    await gate?.future;
    if (fail) {
      await output.onError(failure, StackTrace.current);
    } else {
      await output.onSuccess(const Counter(7));
    }
  }
}

class _Increment implements IncrementCounterInputPort {
  final failure = Exception("save");
  bool fail = true;
  @override
  Future<void> perform(IncrementCounterInputPortParameter parameter, OutputPort<void> output) async {
    if (fail) {
      await output.onError(failure, StackTrace.current);
    } else {
      await output.onSuccess(null);
    }
  }
}

Future<void> _until(CounterBloc bloc, bool Function(CounterState) matches) async {
  if (matches(bloc.state)) return;
  await bloc.stream.firstWhere(matches).timeout(const Duration(seconds: 5));
}

void main() {
  test("Initial load keeps the original failure and can retry when logging throws", () async {
    final fetch = _Fetch()..fail = true;
    final logger = _ThrowingLogger();
    final bloc = CounterBloc(fetchCounter: fetch, incrementCounter: _Increment(), eventSubscriber: _Subscriber(), logger: logger);
    addTearDown(bloc.close);
    bloc.requestInitialLoad(const CounterInitialLoadRequested());
    await _until(bloc, (state) => state is CounterInitializeErrorState);
    expect((bloc.state as CounterInitializeErrorState).cause, same(fetch.failure));
    expect(logger.errors.single, same(fetch.failure));
    fetch.fail = false;
    bloc.add(const CounterRefreshRequested());
    await _until(bloc, (state) => state is CounterPostInitializedReadyState);
    expect((bloc.state as CounterPostInitializedReadyState).data.counter.value, 7);
  });
  test("Save keeps the original failure and data and can retry when logging throws", () async {
    final increment = _Increment();
    final logger = _ThrowingLogger();
    final bloc = CounterBloc(fetchCounter: _Fetch(), incrementCounter: increment, eventSubscriber: _Subscriber(), logger: logger);
    addTearDown(bloc.close);
    bloc.requestInitialLoad(const CounterInitialLoadRequested());
    await _until(bloc, (state) => state is CounterPostInitializedReadyState);
    bloc.add(const CounterIncrementRequested());
    await _until(bloc, (state) => state is CounterPostInitializedErrorState);
    final errorState = bloc.state as CounterPostInitializedErrorState;
    expect(errorState.cause, same(increment.failure));
    expect(logger.errors.single, same(increment.failure));
    expect(errorState.data.counter.value, 7);
    increment.fail = false;
    bloc.add(const CounterIncrementRequested());
    await _until(bloc, (state) => state is CounterPostInitializedCompleteState<void>);
    expect((bloc.state as CounterPostInitializedCompleteState<void>).data.counter.value, 7);
  });
  test("Closing during a pending load removes the subscription", () async {
    final subscriber = _Subscriber();
    final gate = Completer<void>();
    final fetch = _Fetch()..gate = gate;
    final bloc = CounterBloc(fetchCounter: fetch, incrementCounter: _Increment(), eventSubscriber: subscriber, logger: const NoopLogger());
    bloc.requestInitialLoad(const CounterInitialLoadRequested());
    await _until(bloc, (state) => state is CounterInitializeLoadingState);
    final closed = bloc.close();
    verify(() => subscriber.removeListener(bloc)).called(1);
    gate.complete();
    await closed;
    expect(bloc.isClosed, isTrue);
  });
  blocTest<_GuardBloc, CounterState>(
    "A handler that leaves Loading recovers to Error",
    build: _GuardBloc.new,
    act: (bloc) => bloc.add(const CounterRefreshRequested()),
    expect: () => [isA<CounterInitializeLoadingState>(), isA<CounterInitializeErrorState>()],
    errors: () => [isA<core.EventHandlerCompletedInLoadingException>()],
  );
}

class _GuardBloc extends core.BlocBase<CounterBlocEvent, CounterState, CounterStateData> {
  _GuardBloc() : super(initialState: CounterInitializeReadyState(), eventSubscriber: _Subscriber(), logger: const NoopLogger());
  @override
  void handleEvent(CounterBlocEvent event, core.Emitter<CounterState> emit) {
    emit(CounterInitializeLoadingState());
  }
}
