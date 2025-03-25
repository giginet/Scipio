struct WeakReference<Value: AnyObject> {
    weak var reference: Value?

    init(_ value: Value?) {
        self.reference = value
    }
}
