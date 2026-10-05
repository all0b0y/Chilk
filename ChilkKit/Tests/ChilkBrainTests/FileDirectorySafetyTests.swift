import Darwin
import Foundation
import Testing
@testable import ChilkBrain

@Suite("File descriptor and committed-write safety")
struct FileDirectorySafetyTests {
    @Test(arguments: [false, true])
    func searchRejectsAnOpenedDirectoryThatChangedIdentityOrHiddenFlags(_ hidden: Bool) throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First"), second = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let opened = Darwin.open(second.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { Darwin.close(opened) }
        #expect(opened >= 0)
        var expected = stat()
        if hidden {
            #expect(lstat(second.path, &expected) == 0)
            #expect(chflags(second.path, UInt32(UF_HIDDEN)) == 0)
        } else { #expect(lstat(first.path, &expected) == 0) }
        #expect(!ChilkFileToolExecutor.searchableDirectory(opened, expected: expected))
    }
    @Test func aFailedDirectoryStreamDoesNotLeakItsDuplicatedDescriptor() throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { Darwin.close(parent) }
        #expect(parent >= 0)
        var duplicate: Int32 = -1, closed: Int32 = -1
        let stream = ChilkFileToolExecutor.openDirectory(parent, using: { fd in
            duplicate = fd
            #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
            errno = ENOMEM
            return nil
        }, close: { fd in
            closed = fd
            return Darwin.close(fd)
        })
        #expect(stream == nil)
        #expect(duplicate >= 0)
        #expect(closed == duplicate)
        // Do not inspect or close a released fd number: another parallel test could own it now.
        #expect(fcntl(parent, F_GETFD) >= 0)
    }

    @Test func aDirectoryReadErrorIsNotReportedAsEndOfDirectory() throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { Darwin.close(parent) }
        let stream = try #require(fdopendir(dup(parent)))
        defer { closedir(stream) }
        #expect(throws: (any Error).self) {
            _ = try ChilkFileToolExecutor.readDirectoryEntry(stream) { _ in errno = EIO; return nil }
        }
        errno = EIO
        #expect(try ChilkFileToolExecutor.readDirectoryEntry(stream, using: { _ in nil }) == nil)
    }

    @Test func cancellationAfterCommitWarnsThatTheNoteMayHaveChanged() async throws {
        let root = try SelectedFolderToolTests().fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("committed.md")
        try Data("ALREADY COMMITTED\n".utf8).write(to: note)
        let uncertain = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try ChilkFileToolExecutor.verifyCommittedAppend { try Task.checkCancellation(); return true }
                return false
            } catch let error as ChilkFileToolExecutor.FileError {
                if case .writeIncomplete = error { return true }
                return false
            } catch { return false }
        }.value
        #expect(uncertain)
        #expect(try Data(contentsOf: note) == Data("ALREADY COMMITTED\n".utf8))
    }
}
