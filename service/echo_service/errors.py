class ServiceError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retryable: bool = False):
        super().__init__(message)
        self.code, self.message, self.status, self.retryable = code, message, status, retryable

    def payload(self):
        return {"error": {"code": self.code, "message": self.message, "retryable": self.retryable}}
