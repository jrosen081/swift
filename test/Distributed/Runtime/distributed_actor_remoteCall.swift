// XXX: %target-swift-frontend -primary-file %s -emit-sil -parse-as-library -enable-experimental-distributed -disable-availability-checking | %FileCheck %s --enable-var-scope --dump-input=always
// RUN: %target-run-simple-swift( -Xfrontend -module-name=main -Xfrontend -disable-availability-checking -Xfrontend -enable-experimental-distributed -parse-as-library) | %FileCheck %s --dump-input=always
// REQUIRES: executable_test
// REQUIRES: concurrency
// REQUIRES: distributed
// rdar://76038845
// UNSUPPORTED: use_os_stdlib
// UNSUPPORTED: back_deployment_runtime
// FIXME(distributed): Distributed actors currently have some issues on windows, isRemote always returns false. rdar://82593574
// UNSUPPORTED: windows
import _Distributed

final class Obj: @unchecked Sendable, Codable  {}

struct LargeStruct: Sendable, Codable {
  var q: String
  var a: Int
  var b: Int64
  var c: Double
  var d: String
}

enum E : Sendable, Codable {
  case foo, bar
}

@_silgen_name("swift_distributed_actor_is_remote")
func __isRemoteActor(_ actor: AnyObject) -> Bool

distributed actor Greeter {
  distributed func empty() {
  }

  distributed func hello() -> String {
    return "Hello, World!"
  }

  distributed func answer() -> Int {
    return 42
  }

  distributed func largeResult() -> LargeStruct {
    .init(q: "question", a: 42, b: 1, c: 2.0, d: "Lorum ipsum")
  }

  distributed func echo(name: String) -> String {
    return "Echo: \(name)"
  }

  distributed func enumResult() -> E {
    .bar
  }

}


// ==== Fake Transport ---------------------------------------------------------
struct ActorAddress: Sendable, Hashable, Codable {
  let address: String
  init(parse address: String) {
    self.address = address
  }
}

struct FakeActorSystem: DistributedActorSystem {
  typealias ActorID = ActorAddress
  typealias Invocation = FakeInvocation
  typealias SerializationRequirement = Codable

  func resolve<Act>(id: ActorID, as actorType: Act.Type)
    throws -> Act? where Act: DistributedActor {
    return nil
  }

  func assignID<Act>(_ actorType: Act.Type) -> ActorID
    where Act: DistributedActor {
    let id = ActorAddress(parse: "xxx")
    return id
  }

  func actorReady<Act>(_ actor: Act)
    where Act: DistributedActor,
    Act.ID == ActorID {
  }

  func resignID(_ id: ActorID) {
  }

  func makeInvocation() -> Invocation {
    .init()
  }

  func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: Invocation,
    throwing: Err.Type,
    returning: Res.Type
  ) async throws -> Res
    where Act: DistributedActor,
    Act.ID == ActorID,
    Res: SerializationRequirement {
    fatalError("INVOKED REMOTE CALL")
  }

}

struct FakeInvocation: DistributedTargetInvocation {
  typealias ArgumentDecoder = FakeArgumentDecoder
  typealias SerializationRequirement = Codable

  var arguments: [Any] = []

  mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {}
  mutating func recordArgument<Argument: SerializationRequirement>(argument: Argument) throws {
    arguments.append(argument)
  }
  mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {}
  mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
  mutating func doneRecording() throws {}

  // === Receiving / decoding -------------------------------------------------
  mutating func decodeGenericSubstitutions() throws -> [Any.Type] { [] }
  func makeArgumentDecoder() -> FakeArgumentDecoder {
    .init(invocation: self)
  }
  mutating func decodeReturnType() throws -> Any.Type? { nil }
  mutating func decodeErrorType() throws -> Any.Type? { nil }

  struct FakeArgumentDecoder: DistributedTargetInvocationArgumentDecoder {
    typealias SerializationRequirement = Codable
    let invocation: FakeInvocation
    var index: Int = 0

    mutating func decodeNext<Argument>(
      _ argumentType: Argument.Type,
      into pointer: UnsafeMutablePointer<Argument>
    ) throws {
      guard index < invocation.arguments.count else {
        fatalError("Attempted to decode more arguments than stored! Index: \(index), args: \(invocation.arguments)")
      }

      let anyArgument = invocation.arguments[index]
      guard let argument = anyArgument as? Argument else {
        fatalError("Cannot cast argument\(anyArgument) to expected \(Argument.self)")
      }

      print("  > argument: \(argument)")
      pointer.pointee = argument
      index += 1
    }
  }
}

@available(SwiftStdlib 5.5, *)
struct FakeResultHandler: DistributedTargetInvocationResultHandler {
  typealias SerializationRequirement = Codable

  func onReturn<Res>(value: Res) async throws {
    print("RETURN: \(value)")
  }
  func onThrow<Err: Error>(error: Err) async throws {
    print("ERROR: \(error)")
  }
}

@available(SwiftStdlib 5.5, *)
typealias DefaultDistributedActorSystem = FakeActorSystem

// actual mangled name:
let emptyName = "$s4main7GreeterC5emptyyyFTE"
let helloName = "$s4main7GreeterC5helloSSyFTE"
let answerName = "$s4main7GreeterC6answerSiyFTE"
let largeResultName = "$s4main7GreeterC11largeResultAA11LargeStructVyFTE"
let enumResultName = "$s4main7GreeterC10enumResultAA1EOyFTE"

let echoName = "$s4main7GreeterC4echo4nameS2S_tFTE"

func test() async throws {
  let system = FakeActorSystem()

  let local = Greeter(system: system)

  // act as if we decoded an Invocation:
  var invocation = FakeInvocation()

  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: emptyName,
      invocation: &invocation,
      handler: FakeResultHandler()
  )

  // CHECK: RETURN: ()

  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: helloName,
      invocation: &invocation,
      handler: FakeResultHandler()
  )

  // CHECK: RETURN: Hello, World!

  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: answerName,
      invocation: &invocation,
      handler: FakeResultHandler()
  )

  // CHECK: RETURN: 42

  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: largeResultName,
      invocation: &invocation,
      handler: FakeResultHandler()
  )

  // CHECK: RETURN: LargeStruct(q: "question", a: 42, b: 1, c: 2.0, d: "Lorum ipsum")

  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: enumResultName,
      invocation: &invocation,
      handler: FakeResultHandler()
  )
  // CHECK: RETURN: bar
  var echoInvocation = system.makeInvocation()
  try echoInvocation.recordArgument(argument: "Caplin")
  try echoInvocation.doneRecording()
  try await system.executeDistributedTarget(
      on: local,
      mangledTargetName: echoName,
      invocation: &echoInvocation,
      handler: FakeResultHandler()
  )
  // CHECK: RETURN: Echo: Caplin

  print("done")
  // CHECK-NEXT: done
}

@main struct Main {
  static func main() async {
    try! await test()
  }
}
