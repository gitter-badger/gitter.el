;;; gitter.el --- An Emacs Gitter client  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  Chunyang Xu

;; Author: Chunyang Xu <xuchunyang.me@gmail.com>
;; URL: https://github.com/xuchunyang/gitter.el
;; Package-Requires: ((let-alist "1.0.4") (emacs "24.1"))
;; Keywords: Gitter, chat, client, Internet
;; Version: 0.0

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'json)

(defgroup gitter nil
  "An Emacs Gitter client."
  :group 'comm)

;; FIXME: Use `defcustom' instead
(defvar gitter-token nil
  "Your Gitter Personal Access Token.

To get your token:
1) Visit URL `https://developer.gitter.im'
2) Click Sign in (top right)
3) You will see your personal access token at
   URL `https://developer.gitter.im/apps'

DISCLAIMER
When you save this variable, DON'T WRITE IT ANYWHERE PUBLIC.")

(defcustom gitter-curl-program-name "curl"
  "Name/path by which to invoke the curl program."
  :group 'gitter
  :type 'string)

(defvar gitter--root-endpoint "https://api.gitter.im")

(defun gitter--request (method resource &optional params data _noerror)
  ;; PARAMS and DATA should be nil or alist
  (with-current-buffer (generate-new-buffer " *curl*")
    (let* ((p (and params (concat "?" (gitter--url-encode-params params))))
           (d (and data (json-encode-list data)))
           (url (concat gitter--root-endpoint resource p))
           (headers
            (append (and d '("Content-Type: application/json"))
                    (list "Accept: application/json"
                          (format "Authorization: Bearer %s" gitter-token))))
           (args (gitter--curl-args url method headers d)))
      (if (zerop (apply #'call-process gitter-curl-program-name nil t nil args))
          (progn (goto-char (point-min))
                 (re-search-forward "^\r$")
                 (gitter--read-response))
        (error "curl failed")
        (display-buffer (current-buffer))))))

(defun gitter--url-encode-params (params)
  (mapconcat (pcase-lambda (`(,key . ,val))
               (concat (url-hexify-string (symbol-name key)) "="
                       (url-hexify-string val)))
             params "&"))

(defun gitter--curl-args (url method &optional headers data)
  (let ((args ()))
    (push "-s" args)
    (push "-i" args)
    (push "-X" args)
    (push method args)
    (dolist (h headers)
      (push "-H" args)
      (push h args))
    (when data
      (push "-d" args)
      (push data args))
    (nreverse (cons url args))))

(defun gitter--read-response ()
  (let ((json-object-type 'alist)
        (json-array-type  'list)
        (json-key-type    'symbol)
        (json-false       nil)
        (json-null        nil))
    (json-read)))

(defun gitter--json-read-from-string (string)
  (let ((json-object-type 'alist)
        (json-array-type  'list)
        (json-key-type    'symbol)
        (json-false       nil)
        (json-null        nil))
    (json-read-from-string string)))

(defun gitter--open-room (name id)
  (with-current-buffer (get-buffer-create (concat "#" name))
    (unless (get-buffer-process (current-buffer))
      (let* ((url (format "https://stream.gitter.im/v1/rooms/%s/chatMessages" id))
             (headers
              (list "Accept: application/json"
                    (format "Authorization: Bearer %s" gitter-token)))
             (proc
              (apply #'start-process
                     (concat "curl-streaming-process-" name)
                     (current-buffer)
                     gitter-curl-program-name
                     (gitter--curl-args url "GET" headers))))
        (process-put proc 'room-id id)
        ;; FIXME: Must parse json incrementally because
        ;; "The output to the filter may come in chunks of any size"
        ;; Take `notmuch-search-process-filter' as an example
        (set-process-filter proc #'gitter--output-filter)))
    (switch-to-buffer (current-buffer))))

(defun gitter--output-filter (process output)
  (when (buffer-live-p (process-buffer process))
    ;; TODO Try `markdown-mode' since Gitter uses Markdown
    (with-current-buffer (process-buffer process)
      (save-excursion
        (save-restriction
          (goto-char (point-max))
          (condition-case err
              (let-alist (gitter--json-read-from-string output)
                (insert (format "%s @%s" .fromUser.displayName .fromUser.username)
                        "\n"
                        .text
                        "\n"))
            (error                      ; Not vaild json
             ;; Debug
             (with-current-buffer (get-buffer-create "*Debug Gitter Log")
               (goto-char (point-max))
               (insert (format "The error was: %s" err)
                       "\n"
                       output)))))))))

(defvar gitter--user-rooms nil)

;;;###autoload
(defun gitter ()
  "Open a room."
  (interactive)
  (unless gitter--user-rooms
    (setq gitter--user-rooms (gitter--request "GET" "/v1/rooms")))
  ;; FIXME Assuming room name is unique because of `completing-read'
  (let* ((rooms (mapcar (lambda (alist)
                          (let-alist alist
                            (cons .name .id)))
                        gitter--user-rooms))
         (name (completing-read "Open room: " rooms))
         (id (cdr (assoc name rooms))))
    (gitter--open-room name id)))

;; FIXME Just for testing. It is too bad to use Minibuffer to compose message.
;;
;; Maybe try the following layout, assume we are in the room buffer
;;
;; ...
;; Chat history
;; ...
;; 
;; Compose area
;;
(defun gitter-send-message ()
  (interactive)
  (let ((proc (get-buffer-process (current-buffer))))
    (when proc
      (let* ((id (process-get proc 'room-id))
             (resource (format "/v1/rooms/%s/chatMessages" id)))
        (gitter--request "POST" resource
                         nil `((text . ,(read-string "Send message: "))))))))

(provide 'gitter)
;;; gitter.el ends here
